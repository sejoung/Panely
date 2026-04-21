import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main-actor-isolated, `@Observable` store for the reader feature. Stored
/// state lives here; feature methods are split across focused extensions:
///
/// - `ReaderViewModel+Navigation.swift` — page navigation, chrome toggles
/// - `ReaderViewModel+Source.swift` — loading, volume/folder handling, position memory
/// - `ReaderViewModel+ImageLoading.swift` — preload, vertical lazy window, cache
/// - `ReaderViewModel+Bookmarks.swift` — favorites & page bookmarks integration
///
/// Stored properties had to drop `private` / `private(set)` so cross-file
/// extensions can mutate them — in-module encapsulation only. The class is
/// `final` and module-internal, so surface exposure is narrow.
@Observable
@MainActor
final class ReaderViewModel {
    // MARK: - UserDefaults keys

    static let layoutKey = "panely.layout"
    static let directionKey = "panely.direction"
    static let sidebarPinnedKey = "panely.sidebarPinned"
    static let legacySidebarVisibleKey = "panely.sidebarVisible"
    static let positionsKey = "panely.positions"
    static let fitModeKey = "panely.fitMode"
    static let autoFitOnResizeKey = "panely.autoFitOnResize"
    static let toolbarPinnedKey = "panely.toolbarPinned"
    static let thumbnailSidebarVisibleKey = "panely.thumbnailSidebarVisible"

    // MARK: - Source state

    // setter is module-internal so tests can stage a source/page without
    // going through the full file-load pipeline. Production callers should
    // still treat this as read-only and mutate via load(url:) / next() etc.
    var source: ComicSource = .empty
    var currentPageIndex: Int = 0 {
        didSet { savePosition() }
    }
    var currentImages: [NSImage] = []
    var errorMessage: String?
    var isLoading: Bool = false
    var loadingMessage: String = ""

    var currentSourceURL: URL?
    var siblings: [URL] = []

    let recentItems: RecentItemsStore
    let bookmarks: BookmarksStore

    var rootScopedURL: URL?
    var currentTempDir: URL?
    var openedSourceURL: URL?
    var libraryRefreshToken: UUID = UUID()
    var explicitLibraryRootURL: URL?

    // MARK: - Image cache + paged preload

    let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 10
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

    /// Set to true at the end of init. Gates `handleLayoutChange` so that
    /// reading layout back from UserDefaults during init doesn't fire a
    /// premature handleLayoutChange (which would set isLoading=true with no
    /// source loaded — visible to tests and producing a wasted Task).
    var isFullyInitialized = false

    // MARK: - Preferences (persisted via didSet)

    var layout: PageLayout = .single {
        didSet { handleLayoutChange(from: oldValue) }
    }

    var direction: ReadingDirection = .leftToRight {
        didSet {
            UserDefaults.standard.set(direction.rawValue, forKey: Self.directionKey)
        }
    }

    /// Direction used for navigation/page-ordering decisions. In continuous
    /// (vertical) layouts the user's RTL preference doesn't apply — webtoons
    /// are top-to-bottom — but the underlying `direction` is preserved so it
    /// returns once paged mode resumes.
    var effectiveDirection: ReadingDirection {
        layout.isContinuous ? .leftToRight : direction
    }

    var sidebarMode = SidebarMode() {
        didSet {
            UserDefaults.standard.set(sidebarMode.pinned, forKey: Self.sidebarPinnedKey)
        }
    }

    var sidebarVisible: Bool { sidebarMode.visible }
    var sidebarPinned: Bool { sidebarMode.pinned }
    var sidebarOverlayVisible: Bool { sidebarMode.overlayVisible }

    var fitMode: FitMode = .fitScreen {
        didSet {
            UserDefaults.standard.set(fitMode.rawValue, forKey: Self.fitModeKey)
        }
    }

    /// When true (default), the viewer re-applies the current fit mode on
    /// window/sidebar resize. When false, the user's magnification is left
    /// alone — useful when they've manually zoomed and want their view
    /// preserved across layout shifts.
    var autoFitOnResize: Bool = true {
        didSet {
            UserDefaults.standard.set(autoFitOnResize, forKey: Self.autoFitOnResizeKey)
        }
    }

    /// When true, the floating toolbar (and bottom slider) stays visible
    /// instead of auto-hiding. Default false matches the distraction-free
    /// reading experience; opt-in for users who want quick access to
    /// controls or progress info while reading.
    var toolbarPinned: Bool = false {
        didSet {
            UserDefaults.standard.set(toolbarPinned, forKey: Self.toolbarPinnedKey)
        }
    }

    /// Right-side thumbnail panel visibility. Off by default — users opt in
    /// via the toolbar button or `⌃⌘P`. Persisted so the preference survives
    /// app restarts.
    var thumbnailSidebarVisible: Bool = false {
        didSet {
            UserDefaults.standard.set(thumbnailSidebarVisible, forKey: Self.thumbnailSidebarVisibleKey)
        }
    }

    // MARK: - Trivial derived state

    var totalPages: Int { source.pageCount }
    var hasSource: Bool { !source.isEmpty }
    var navigationStep: Int { layout.navigationStep }

    // MARK: - Init

    init() {
        self.recentItems = RecentItemsStore()
        self.bookmarks = BookmarksStore()

        // Snapshot once. Each individual `UserDefaults.standard.string(...)`
        // / `.bool(...)` / `.object(...)` call is a syscall + KVO check; on
        // cold start the dozen lookups added up to ~10–50 ms. A single
        // `dictionaryRepresentation()` is one cross-process trip and we
        // type-cast from in-memory dict locally.
        let defaults = UserDefaults.standard.dictionaryRepresentation()

        if let raw = defaults[Self.layoutKey] as? String,
           let stored = PageLayout(rawValue: raw) {
            layout = stored
        }
        if let raw = defaults[Self.directionKey] as? String,
           let stored = ReadingDirection(rawValue: raw) {
            direction = stored
        }
        if let pinned = defaults[Self.sidebarPinnedKey] as? Bool {
            sidebarMode.pinned = pinned
        } else if let legacy = defaults[Self.legacySidebarVisibleKey] as? Bool {
            // Migrate prior "always visible" preference to the new pinned mode.
            sidebarMode.pinned = legacy
        }
        if let raw = defaults[Self.fitModeKey] as? String,
           let stored = FitMode(rawValue: raw) {
            fitMode = stored
        }
        if let value = defaults[Self.autoFitOnResizeKey] as? Bool {
            autoFitOnResize = value
        }
        if let value = defaults[Self.toolbarPinnedKey] as? Bool {
            toolbarPinned = value
        }
        if let value = defaults[Self.thumbnailSidebarVisibleKey] as? Bool {
            thumbnailSidebarVisible = value
        }

        isFullyInitialized = true
    }
}
