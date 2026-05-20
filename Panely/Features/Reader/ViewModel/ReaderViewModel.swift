import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main-actor-isolated, `@Observable` store for the reader feature.
///
/// Composition over inheritance: state and persistence that don't depend on
/// the open book live in dedicated collaborators, so this class only carries
/// the source/image/navigation state that genuinely belongs together:
///
/// - `ReaderPreferences` — layout / fit / sidebar / toolbar persistence
/// - `ReaderPositionStore` — debounced per-book page memory
/// - `ReaderViewModel+Navigation` — page stepping, chrome toggles, jumps
/// - `ReaderViewModel+Source` — load pipeline, volume siblings, temp dirs
/// - `ReaderViewModel+ImageLoading` — preload, vertical lazy window, cache
/// - `ReaderViewModel+Bookmarks` — favorites & per-page bookmarks integration
///
/// The preferences fields (`layout`, `fitMode`, …) are exposed as forwarding
/// computed properties on this class so existing view callsites
/// (`viewModel.layout == .single`) keep working unchanged — `@Observable`
/// tracks through the chain to `preferences.layout`.
@Observable
@MainActor
final class ReaderViewModel {
    // MARK: - Collaborators

    let preferences = ReaderPreferences()
    let positions = ReaderPositionStore()
    let recentItems: RecentItemsStore
    let bookmarks: BookmarksStore

    // MARK: - Source state

    var source: ComicSource = .empty
    var currentPageIndex: Int = 0 {
        didSet {
            savePosition()
            // Any page-change clears the "show prev-volume card" cue. The
            // backward path re-sets it immediately after the assignment when
            // landing on page 0, so we don't lose intent there.
            wantsPreviousVolumePrompt = false
        }
    }
    var currentImages: [NSImage] = []
    var errorMessage: String?
    var isLoading: Bool = false
    var loadingMessage: String = ""

    var currentSourceURL: URL?
    var siblings: [URL] = []

    /// One-press cue for advancing to the previous volume from page 0.
    /// Set by `goBackward()` (either when arriving at 0 from a higher page,
    /// or on an explicit backward press at 0). Cleared by any page change
    /// (`currentPageIndex` didSet) and by `load(url:)`.
    var wantsPreviousVolumePrompt: Bool = false

    var rootScopedURL: URL?
    var currentTempDir: URL?
    var openedSourceURL: URL?
    var libraryRefreshToken: UUID = UUID()
    var explicitLibraryRootURL: URL?

    /// Monotonic counter incremented at the start of every `load(url:)` call.
    /// Each in-flight load captures the value, then re-checks it after every
    /// `await`. If the counter has advanced, a newer load has started and
    /// the older one bails out without writing stale state. Without this,
    /// rapid book switches could leave the viewer showing the result of an
    /// earlier-clicked book that happened to finish loading after the later
    /// one (race in `currentImages` / `currentSourceURL` assignments).
    var loadEpoch: Int = 0

    // MARK: - Image cache + paged preload

    let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // countLimit is intentionally loose — the real budget is `totalCostLimit`.
        // Vertical lazy windows (`lazyWindowRadius` + `lazyKeepBuffer`) can pin
        // ~25 pages around the visible band; setting the count cap close to that
        // caused premature eviction of small pages even when far under the byte
        // budget, hurting prefetch hit-rate on flips. Cost-driven eviction does
        // the right thing for both huge and small pages.
        cache.countLimit = 100
        // High-res scans (10000×14000 ≈ 600 MB decoded) could otherwise stack
        // up to many GB of RSS. The byte cap means typical smaller pages stay
        // cached generously, while a few huge pages get evicted before they
        // pin too much memory. Per-entry cost is fed in by `cacheImage(_:for:)`
        // based on pixel area × 4.
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()
    var preloadTask: Task<Void, Never>?
    let preloadRadius = 2

    // MARK: - Vertical lazy window

    /// Vertical-mode lazy-load state. `pageDimensions` is populated up-front
    /// (cheap header reads); `currentImages` starts as same-sized placeholder
    /// `NSImage(size:)` instances and is replaced one-by-one as real images
    /// are decoded inside the visible window. `loadedPageIndices` tracks
    /// which slots already hold real (non-placeholder) images.
    var pageDimensions: [CGSize] = []
    var loadedPageIndices: Set<Int> = []
    let lazyWindowRadius = 3
    /// Pages outside `[visibleRange ± lazyKeepBuffer]` get evicted back to
    /// placeholders so a long strip doesn't pin every loaded image in memory.
    /// Wider than the load buffer so small back-scrolls don't immediately
    /// re-decode. NSCache still holds recents for fast restore.
    let lazyKeepBuffer = 10
    var lazyLoadTask: Task<Void, Never>?

    // MARK: - Preference forwarding (preserves existing view API)

    var layout: PageLayout {
        get { preferences.layout }
        set {
            let oldValue = preferences.layout
            preferences.layout = newValue
            if oldValue != newValue {
                handleLayoutChange(from: oldValue)
            }
        }
    }

    var direction: ReadingDirection {
        get { preferences.direction }
        set { preferences.direction = newValue }
    }

    var fitMode: FitMode {
        get { preferences.fitMode }
        set { preferences.fitMode = newValue }
    }

    var autoFitOnResize: Bool {
        get { preferences.autoFitOnResize }
        set { preferences.autoFitOnResize = newValue }
    }

    var toolbarPinned: Bool {
        get { preferences.toolbarPinned }
        set { preferences.toolbarPinned = newValue }
    }

    var thumbnailSidebarVisible: Bool {
        get { preferences.thumbnailSidebarVisible }
        set { preferences.thumbnailSidebarVisible = newValue }
    }

    var sidebarMode: SidebarMode {
        get { preferences.sidebarMode }
        set { preferences.sidebarMode = newValue }
    }

    var sidebarVisible: Bool { sidebarMode.visible }
    var sidebarPinned: Bool { sidebarMode.pinned }
    var sidebarOverlayVisible: Bool { sidebarMode.overlayVisible }

    /// Direction used for navigation/page-ordering decisions. In continuous
    /// (vertical) layouts the user's RTL preference doesn't apply — webtoons
    /// are top-to-bottom — but the underlying `direction` is preserved so it
    /// returns once paged mode resumes.
    var effectiveDirection: ReadingDirection {
        layout.isContinuous ? .leftToRight : direction
    }

    // MARK: - Trivial derived state

    var totalPages: Int { source.pageCount }
    var hasSource: Bool { !source.isEmpty }
    var navigationStep: Int { layout.navigationStep }

    // MARK: - Init

    init() {
        self.recentItems = RecentItemsStore()
        self.bookmarks = BookmarksStore()

        observeAppTermination()

        // Fire-and-forget: a previous session may have crashed mid-extraction
        // and orphaned a `panely-*` temp dir. Do this off the main actor so
        // a slow tmp scan doesn't delay first paint.
        Task.detached(priority: .background) {
            Self.cleanupStaleTempDirs()
        }
    }

    /// Flush any pending debounced save when the process is about to exit.
    /// The Task is captured weakly via the notification stream's self-capture
    /// pattern — once the VM is gone the handler is a no-op, so the wait
    /// doesn't extend the VM's lifetime.
    private func observeAppTermination() {
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.willTerminateNotification) {
                self?.flushPositionImmediately()
                break
            }
        }
    }
}
