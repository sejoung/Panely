import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main-actor-isolated, `@Observable` store for the reader feature.
///
/// Composition over inheritance: state and persistence that don't depend on
/// the open book live in dedicated collaborators, so this class only carries
/// the navigation/source plumbing that genuinely belongs together:
///
/// - `ReaderPreferences` — **owns all UI/chrome state** (layout, direction,
///   fit, sidebar/toolbar pin, thumbnail visibility). Persists each via
///   `UserDefaults` on assignment.
/// - `ReaderPositionStore` — debounced per-book page memory + key derivation.
/// - `ReaderImageLoader` — cache, lazy window, preload, paged refresh.
/// - `ReaderTempDirectory` — zip-in-zip extraction lifecycle.
/// - `ReaderViewModel+Source` — open entry points, library root, scope helpers.
/// - `ReaderViewModel+LoadPipeline` — the `load(url:)` state machine.
/// - `ReaderViewModel+Navigation` — page stepping, chrome toggles, jumps.
/// - `ReaderViewModel+ImageLoading` — thin facade over `imageLoader`.
/// - `ReaderViewModel+Bookmarks` — favorites + per-page bookmarks.
/// - `ReaderViewModel+Toolbar` — toolbar state/actions wiring.
/// - `ReaderViewModel+Cache` — extraction-cache management.
///
/// **State separation:** domain state lives directly on this class (`source`,
/// `currentPageIndex`, `siblings`, error/loading flags). UI state lives on
/// `ReaderPreferences`. The forwarding computed properties below (`layout`,
/// `direction`, …) preserve a stable view-facing API; `@Observable` tracks
/// through them so views never need to know about the collaborator. The
/// `layout` setter additionally calls `handleLayoutChange` to refresh images
/// — see `ReaderViewModel+ImageLoading`.
@Observable
@MainActor
final class ReaderViewModel {
    // MARK: - Collaborators

    let preferences: ReaderPreferences
    let positions: ReaderPositionStore
    let readingProgress: ReadingProgressStore
    let lastLibraryRoot: LastLibraryRootStore
    let imageLoader = ReaderImageLoader()
    let tempDir: ReaderTempDirectory
    let libraryScope = ReaderLibraryScope()
    let dependencies: AppDependencies
    let recentItems: RecentItemsStore
    let favorites: FavoritesStore
    let pageBookmarks: PageBookmarksStore
    let makeSourceChangeMonitor: @MainActor () -> any SourceChangeMonitoring
    let makeLibraryDirectoryWatcher: @MainActor () -> any LibraryDirectoryWatching

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
    var errorMessage: String?
    var isLoading: Bool = false
    var loadingMessage: String = ""

    var currentSourceURL: URL?
    var pendingSourceURL: URL?
    var siblings: [URL] = []
    var sourceRenderRevision: Int = 0
    var sourceChangedOnDisk: Bool = false
    var sourceChangeMessage: String?
    var sourceChangeMonitor: (any SourceChangeMonitoring)?

    /// Recursive watcher on the current library root. Bumps `libraryRefreshToken`
    /// when files appear/disappear on disk so the sidebar tree auto-refreshes.
    /// `watchedLibraryRootURL` records what it's currently pointed at so
    /// `syncLibraryWatcher()` can skip redundant restarts.
    var libraryDirectoryWatcher: (any LibraryDirectoryWatching)?
    var watchedLibraryRootURL: URL?

    /// One-press cue for advancing to the previous volume from page 0.
    /// Set by `goBackward()` (either when arriving at 0 from a higher page,
    /// or on an explicit backward press at 0). Cleared by any page change
    /// (`currentPageIndex` didSet) and by `load(url:)`.
    var wantsPreviousVolumePrompt: Bool = false

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

    // MARK: - UI-state forwarding to `ReaderPreferences`
    //
    // These properties keep the historical `viewModel.layout` / `.direction`
    // / … API at view callsites. `ReaderPreferences` is the actual source of
    // truth (and the persistence layer); changes flow through these setters.
    // The `layout` setter additionally triggers `handleLayoutChange` so an
    // image refresh and page-index snap happen on the same call.

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

    // MARK: - Image-loader forwarding (preserves existing view API)

    var currentImages: [NSImage] {
        get { imageLoader.currentImages }
        set { imageLoader.currentImages = newValue }
    }

    var pageDimensions: [CGSize] {
        get { imageLoader.pageDimensions }
        set { imageLoader.pageDimensions = newValue }
    }

    // MARK: - Trivial derived state

    var totalPages: Int { source.pageCount }
    var hasSource: Bool { !source.isEmpty }
    var navigationStep: Int { layout.navigationStep }

    // MARK: - Init

    init(dependencies: AppDependencies = .live) {
        self.dependencies = dependencies
        self.preferences = dependencies.makeReaderPreferences()
        self.positions = dependencies.makeReaderPositions()
        self.readingProgress = dependencies.makeReadingProgress()
        self.lastLibraryRoot = dependencies.makeLastLibraryRoot()
        self.tempDir = dependencies.makeReaderTempDirectory()
        self.recentItems = RecentItemsStore(
            bookmarks: dependencies.bookmarkResolver,
            defaults: dependencies.keyValueStore
        )
        self.favorites = FavoritesStore(
            bookmarks: dependencies.bookmarkResolver,
            defaults: dependencies.keyValueStore
        )
        self.pageBookmarks = PageBookmarksStore(defaults: dependencies.keyValueStore)
        self.makeSourceChangeMonitor = dependencies.sourceChangeMonitorFactory
        self.makeLibraryDirectoryWatcher = dependencies.libraryDirectoryWatcherFactory

        observeAppTermination()

        // Fire-and-forget: a previous session may have crashed mid-extraction
        // and orphaned a `panely-*` temp dir. Do this off the main actor so
        // a slow tmp scan doesn't delay first paint.
        let extractionCache = dependencies.extractionCache
        Task.detached(priority: .background) {
            ReaderTempDirectory.cleanupStaleEntries(extractionCache: extractionCache)
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
