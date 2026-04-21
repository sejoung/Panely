import AppKit
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class ReaderViewModel {
    private static let layoutKey = "panely.layout"
    private static let directionKey = "panely.direction"
    private static let sidebarPinnedKey = "panely.sidebarPinned"
    private static let legacySidebarVisibleKey = "panely.sidebarVisible"
    private static let positionsKey = "panely.positions"
    private static let fitModeKey = "panely.fitMode"
    private static let autoFitOnResizeKey = "panely.autoFitOnResize"
    private static let toolbarPinnedKey = "panely.toolbarPinned"
    private static let thumbnailSidebarVisibleKey = "panely.thumbnailSidebarVisible"

    // setter is module-internal so tests can stage a source/page without
    // going through the full file-load pipeline. Production callers should
    // still treat this as read-only and mutate via load(url:) / next() etc.
    var source: ComicSource = .empty
    var currentPageIndex: Int = 0 {
        didSet { savePosition() }
    }
    private(set) var currentImages: [NSImage] = []
    private(set) var errorMessage: String?
    private(set) var isLoading: Bool = false
    private(set) var loadingMessage: String = ""

    private(set) var currentSourceURL: URL?
    private(set) var siblings: [URL] = []

    let recentItems: RecentItemsStore
    let bookmarks: BookmarksStore

    private var rootScopedURL: URL?
    private var currentTempDir: URL?
    private var openedSourceURL: URL?
    private(set) var libraryRefreshToken: UUID = UUID()
    private var explicitLibraryRootURL: URL?

    private let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 10
        return cache
    }()
    private var preloadTask: Task<Void, Never>?
    private let preloadRadius = 2

    /// Vertical-mode lazy-load state. `pageDimensions` is populated up-front
    /// (cheap header reads); `currentImages` starts as same-sized placeholder
    /// `NSImage(size:)` instances and is replaced one-by-one as real images
    /// are decoded inside the visible window. `loadedPageIndices` tracks
    /// which slots already hold real (non-placeholder) images.
    private(set) var pageDimensions: [CGSize] = []
    private var loadedPageIndices: Set<Int> = []
    private let lazyWindowRadius = 3
    /// Pages outside `[visibleRange ± lazyKeepBuffer]` get evicted back to
    /// placeholders so a long strip doesn't pin every loaded image in memory.
    /// Wider than the load buffer so small back-scrolls don't immediately
    /// re-decode. NSCache still holds recents for fast restore.
    private let lazyKeepBuffer = 10
    private var lazyLoadTask: Task<Void, Never>?

    /// Set to true at the end of init. Gates `handleLayoutChange` so that
    /// reading layout back from UserDefaults during init doesn't fire a
    /// premature handleLayoutChange (which would set isLoading=true with no
    /// source loaded — visible to tests and producing a wasted Task).
    private var isFullyInitialized = false

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

    private var sidebarMode = SidebarMode() {
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

    var totalPages: Int { source.pageCount }
    var hasSource: Bool { !source.isEmpty }

    var navigationStep: Int { layout.navigationStep }

    var visiblePages: [ComicPage] {
        if layout.isContinuous {
            return source.pages
        }
        let start = currentPageIndex
        guard source.pages.indices.contains(start) else { return [] }
        let end = min(start + navigationStep, source.pageCount)
        return Array(source.pages[start..<end])
    }

    var pageCounterLabel: String {
        guard !source.isEmpty else { return "" }
        let count = totalPages
        let first = currentPageIndex + 1
        let last = min(currentPageIndex + navigationStep, count)
        return first == last ? "\(first) / \(count)" : "\(first)-\(last) / \(count)"
    }

    /// 1-indexed first page in the currently visible span.
    var currentPageNumber: Int {
        source.isEmpty ? 0 : currentPageIndex + 1
    }

    /// 1-indexed last page in the currently visible span. Matches
    /// `currentPageNumber` outside double-page mode.
    var currentPageRangeEndNumber: Int {
        guard !source.isEmpty else { return 0 }
        return min(currentPageIndex + navigationStep, totalPages)
    }

    /// Jump to a 1-indexed page number. Clamps silently, so callers can pass
    /// user input without pre-validation.
    func jump(toPageNumber pageNumber: Int) {
        guard totalPages > 0 else { return }
        let clamped = min(max(pageNumber, 1), totalPages)
        jump(to: clamped - 1)
    }

    // MARK: - Bookmarks

    /// Stable key for the current book. Nil when no source is open.
    var currentPositionKey: String? {
        guard let url = currentSourceURL else { return nil }
        return positionKey(for: url)
    }

    var isCurrentBookFavorite: Bool {
        guard let url = currentSourceURL else { return false }
        return bookmarks.isFavorite(url: url)
    }

    func toggleFavoriteForCurrentBook() {
        guard let url = currentSourceURL else { return }
        bookmarks.toggleFavorite(url: url, title: displayTitle(for: url))
    }

    var isCurrentPageBookmarked: Bool {
        guard let key = currentPositionKey else { return false }
        return bookmarks.isPageBookmarked(key: key, pageIndex: currentPageIndex)
    }

    func toggleCurrentPageBookmark() {
        guard let key = currentPositionKey else { return }
        bookmarks.togglePageBookmark(key: key, pageIndex: currentPageIndex)
    }

    var currentBookPageBookmarks: [PageBookmark] {
        guard let key = currentPositionKey else { return [] }
        return bookmarks.pageBookmarks(forKey: key)
    }

    var hasPageBookmarks: Bool {
        !currentBookPageBookmarks.isEmpty
    }

    var canGoNextBookmark: Bool {
        guard let key = currentPositionKey else { return false }
        return bookmarks.nextBookmark(forKey: key, after: currentPageIndex) != nil
    }

    var canGoPreviousBookmark: Bool {
        guard let key = currentPositionKey else { return false }
        return bookmarks.previousBookmark(forKey: key, before: currentPageIndex) != nil
    }

    func jumpToNextBookmark() {
        guard let key = currentPositionKey,
              let bm = bookmarks.nextBookmark(forKey: key, after: currentPageIndex) else { return }
        jump(to: bm.pageIndex)
    }

    func jumpToPreviousBookmark() {
        guard let key = currentPositionKey,
              let bm = bookmarks.previousBookmark(forKey: key, before: currentPageIndex) else { return }
        jump(to: bm.pageIndex)
    }

    func jumpToBookmark(_ bookmark: PageBookmark) {
        jump(to: bookmark.pageIndex)
    }

    /// Open a favorite book, resolving its security-scoped bookmark the same
    /// way recent items do.
    func openFavorite(_ favorite: FavoriteBook) {
        guard let url = bookmarks.resolve(favorite) else { return }
        recentItems.record(url, title: displayTitle(for: url))
        Task { await load(url: url) }
    }

    var currentSiblingIndex: Int? {
        guard let current = currentSourceURL else { return nil }
        let target = current.standardizedFileURL
        return siblings.firstIndex { $0.standardizedFileURL == target }
    }

    var hasMultipleVolumes: Bool { siblings.count > 1 }

    var canGoPreviousVolume: Bool {
        guard let idx = currentSiblingIndex else { return false }
        return idx > 0
    }

    var canGoNextVolume: Bool {
        guard let idx = currentSiblingIndex else { return false }
        return idx + 1 < siblings.count
    }

    var volumeCounterLabel: String? {
        guard hasMultipleVolumes, let idx = currentSiblingIndex else { return nil }
        return "Vol \(idx + 1) / \(siblings.count)"
    }

    var combinedCounterLabel: String {
        guard let vol = volumeCounterLabel else { return pageCounterLabel }
        return "\(vol) · \(pageCounterLabel)"
    }

    var libraryRootURL: URL? {
        explicitLibraryRootURL ?? currentSourceURL?.deletingLastPathComponent()
    }

    func openSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"

        var types: [UTType] = [.folder, .zip]
        if let cbz = UTType(filenameExtension: "cbz") {
            types.append(cbz)
        }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK, let url = panel.url else { return }
        recentItems.record(url, title: displayTitle(for: url))
        Task { await load(url: url) }
    }

    func openURL(_ url: URL) {
        recentItems.record(url, title: displayTitle(for: url))
        Task { await load(url: url) }
    }

    func requestFolderAccess() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Select a folder to browse books from."
        if let parent = currentSourceURL?.deletingLastPathComponent() {
            panel.directoryURL = parent
        }

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        rootScopedURL?.stopAccessingSecurityScopedResource()
        rootScopedURL = nil
        if folderURL.startAccessingSecurityScopedResource() {
            rootScopedURL = folderURL
        }

        recentItems.record(folderURL, title: displayTitle(for: folderURL))
        explicitLibraryRootURL = folderURL

        Task {
            let volumes = await Self.enumerateVolumes(in: folderURL)
            if let current = currentSourceURL, isInsideRootScope(current) {
                siblings = volumes.isEmpty ? [current] : volumes
            }
            libraryRefreshToken = UUID()
        }
    }

    private func displayTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Sync the page index with the viewer's current scroll position in
    /// continuous (vertical) layouts. Just updates the page counter / saved
    /// position — actual loading is driven by `setVisibleRange(_:)` so that
    /// zoomed-out viewports get every visible slot loaded, not just ±radius
    /// around the center page.
    func setCurrentPageFromScroll(_ index: Int) {
        guard layout.isContinuous else { return }
        guard source.pages.indices.contains(index) else { return }
        guard index != currentPageIndex else { return }
        currentPageIndex = index
    }

    /// Called when the visible page range in the viewer changes (scroll or
    /// magnification). Loads every page in `range` plus a small buffer so
    /// pages just outside the viewport are ready when the user scrolls.
    /// Cancels any prior in-flight load so fast zoom/scroll doesn't pile
    /// up tasks all racing to finish. Also evicts pages outside the keep
    /// window so big strips don't pin every loaded image in memory.
    func setVisibleRange(_ range: Range<Int>) {
        guard layout.isContinuous else { return }
        guard !range.isEmpty else { return }

        // Free pages outside the keep window first — runs sync so memory
        // is released even if the load below gets cancelled by another
        // setVisibleRange before completing.
        evictPagesOutsideKeepWindow(visibleRange: range)

        let buffer = 2
        let lower = max(0, range.lowerBound - buffer)
        let upper = min(source.pageCount, range.upperBound + buffer)
        let needed = (lower..<upper).filter { !loadedPageIndices.contains($0) }
        guard !needed.isEmpty else { return }

        lazyLoadTask?.cancel()
        lazyLoadTask = Task { [weak self] in
            await self?.loadPagesBatched(needed)
        }
    }

    /// Replace pages outside `[range ± lazyKeepBuffer]` with placeholder
    /// NSImages so their decoded bitmaps can be released. NSCache still
    /// holds the recently-decoded images, so scrolling back within a few
    /// pages typically hits the cache and re-displays instantly.
    private func evictPagesOutsideKeepWindow(visibleRange: Range<Int>) {
        guard !pageDimensions.isEmpty, !loadedPageIndices.isEmpty else { return }
        let lower = max(0, visibleRange.lowerBound - lazyKeepBuffer)
        let upper = min(currentImages.count, visibleRange.upperBound + lazyKeepBuffer)

        var newImages = currentImages
        var evicted: [Int] = []
        for i in loadedPageIndices where i < lower || i >= upper {
            guard i < newImages.count, i < pageDimensions.count else { continue }
            newImages[i] = Self.makePlaceholder(size: pageDimensions[i])
            evicted.append(i)
        }
        guard !evicted.isEmpty else { return }
        for i in evicted { loadedPageIndices.remove(i) }
        currentImages = newImages
    }

    /// Load `indices` concurrently and apply ALL results in a single
    /// `currentImages` assignment. Single SwiftUI render = single
    /// updateNSView = single setImages incremental swap, regardless of how
    /// many pages were just loaded. Critical when zoom-out triggers many
    /// pages to load at once — without batching, each completion fires its
    /// own re-render and the main thread saturates.
    private func loadPagesBatched(_ indices: [Int]) async {
        guard !indices.isEmpty else { return }
        var loaded: [(Int, NSImage)] = []
        let maxConcurrent = Self.lazyConcurrencyLimit

        // Decode in bounded chunks. Decoding is CPU-heavy so spawning every
        // page at once would saturate the pool with no real benefit (cores
        // are bounded anyway) while still costing per-task overhead.
        for chunkStart in stride(from: 0, to: indices.count, by: maxConcurrent) {
            if Task.isCancelled { return }
            let chunkEnd = min(chunkStart + maxConcurrent, indices.count)
            await withTaskGroup(of: (Int, NSImage?).self) { group in
                for i in chunkStart..<chunkEnd {
                    let pageIndex = indices[i]
                    guard !loadedPageIndices.contains(pageIndex),
                          source.pages.indices.contains(pageIndex) else { continue }
                    let page = source.pages[pageIndex]
                    group.addTask {
                        let image = await self.loadVisibleImage(page)
                        return (pageIndex, image)
                    }
                }
                for await (pageIndex, image) in group {
                    if Task.isCancelled { return }
                    if let image {
                        loaded.append((pageIndex, image))
                        loadedPageIndices.insert(pageIndex)
                    }
                }
            }
        }

        guard !Task.isCancelled, !loaded.isEmpty else { return }
        // Take a fresh snapshot — concurrent evictions or other lazy loads
        // may have mutated currentImages during the awaits above. Merge our
        // new pages into the latest state and write once.
        var newImages = currentImages
        for (i, image) in loaded where i < newImages.count {
            newImages[i] = image
        }
        currentImages = newImages
    }

    /// Concurrency cap for header-fetch / decode TaskGroups. ~Core count
    /// keeps the pool busy without overcommitting; clamped to [2, 8] so
    /// neither single-core hosts nor monster CPUs spin up pathological
    /// numbers of tasks.
    private static var lazyConcurrencyLimit: Int {
        max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
    }

    func toggleSidebarPin() {
        sidebarMode.togglePin()
    }

    func revealSidebarOverlay() {
        sidebarMode.revealOverlay()
    }

    func dismissSidebarOverlay() {
        sidebarMode.dismissOverlay()
    }

    func next() {
        let target = currentPageIndex + navigationStep
        guard target < source.pageCount else { return }
        currentPageIndex = target
        scheduleRefreshIfPaged()
    }

    func previous() {
        let target = currentPageIndex - navigationStep
        guard target >= 0 else {
            guard currentPageIndex > 0 else { return }
            currentPageIndex = 0
            scheduleRefreshIfPaged()
            return
        }
        currentPageIndex = target
        scheduleRefreshIfPaged()
    }

    func jump(to index: Int) {
        let step = navigationStep
        let snapped = (index / step) * step
        let clamped = min(max(snapped, 0), max(0, source.pageCount - 1))
        guard clamped != currentPageIndex else { return }
        currentPageIndex = clamped
        scheduleRefreshIfPaged()
    }

    /// In continuous (vertical) layouts the entire strip is already loaded,
    /// so paging just means scrolling — no need to re-iterate every page
    /// through ImageLoader on every keystroke.
    private func scheduleRefreshIfPaged() {
        guard !layout.isContinuous else { return }
        Task { await refreshImages() }
    }

    func nextVolume() {
        guard canGoNextVolume, let idx = currentSiblingIndex else { return }
        let target = siblings[idx + 1]
        let preservedSiblings = siblings
        Task { await load(url: target, knownSiblings: preservedSiblings) }
    }

    func previousVolume() {
        guard canGoPreviousVolume, let idx = currentSiblingIndex else { return }
        let target = siblings[idx - 1]
        let preservedSiblings = siblings
        Task { await load(url: target, knownSiblings: preservedSiblings) }
    }

    func toggleLayout() {
        // Don't auto-change fitMode on layout transitions — the user's last
        // explicit fit choice is preserved. If they want a different fit
        // for the new mode they can press ⌘1/⌘2/⌘3. Combined with applyFit
        // not force-resetting magnification on layout-only changes, this
        // means a manually-zoomed viewer stays at that zoom across modes.
        layout = layout.next
    }

    func toggleDirection() {
        // Vertical strips have no left/right semantics — let the user keep
        // their preference for when they return to a paged layout.
        guard !layout.isContinuous else { return }
        direction = direction.isRTL ? .leftToRight : .rightToLeft
    }

    func toggleFitMode() {
        fitMode = fitMode.next
    }

    func toggleAutoFitOnResize() {
        autoFitOnResize.toggle()
    }

    func toggleToolbarPin() {
        toolbarPinned.toggle()
    }

    func toggleThumbnailSidebar() {
        thumbnailSidebarVisible.toggle()
    }

    private func handleLayoutChange(from oldLayout: PageLayout) {
        // Skip when init is restoring from UserDefaults — there's no source
        // to refresh and we don't want a phantom isLoading=true.
        guard isFullyInitialized else { return }

        UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey)
        let step = navigationStep
        currentPageIndex = (currentPageIndex / step) * step

        // Going from paged to vertical: clear stale paged images and show
        // a loading indicator immediately. Without this the user sees the
        // viewer's empty state for the duration of the dimension fetch +
        // initial window load (which can be a noticeable beat for big
        // folders). refreshVerticalLazily / refreshImages clear isLoading
        // when they finish.
        if layout.isContinuous && !oldLayout.isContinuous {
            currentImages = []
            isLoading = true
            loadingMessage = "Building vertical strip…"
        }
        Task { await refreshImages() }
    }

    private func load(url: URL, knownSiblings: [URL]? = nil) async {
        preloadTask?.cancel()

        isLoading = true
        loadingMessage = "Opening…"
        defer {
            isLoading = false
            loadingMessage = ""
        }

        if !isInsideCurrentTree(url) {
            cleanupTempDir()
            rootScopedURL?.stopAccessingSecurityScopedResource()
            rootScopedURL = nil
            if url.startAccessingSecurityScopedResource() {
                rootScopedURL = url
            }
            explicitLibraryRootURL = nil
            openedSourceURL = url
        }

        var targetURL = url
        var siblingsToUse = knownSiblings

        if currentTempDir == nil {
            let ext = url.pathExtension.lowercased()
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDir && CBZLoader.supportedExtensions.contains(ext) {
                loadingMessage = "Analyzing archive…"
                if let hasNested = try? await CBZLoader.hasNestedArchives(at: url), hasNested {
                    loadingMessage = "Extracting archive…"
                    let tempDir = Self.makeTempDir()
                    do {
                        try await CBZLoader.extractAll(from: url, to: tempDir)
                        currentTempDir = tempDir
                        targetURL = tempDir
                    } catch {
                        try? FileManager.default.removeItem(at: tempDir)
                        errorMessage = "Failed to extract archive: \(error.localizedDescription)"
                    }
                }
            }
        }

        let isDirectory = (try? targetURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

        if isDirectory {
            loadingMessage = "Scanning folder…"
            let (hasImages, volumes) = await Self.analyzeFolder(targetURL)

            if !hasImages && !volumes.isEmpty {
                guard let first = volumes.first else { return }
                targetURL = first
                siblingsToUse = volumes
            } else if !hasImages && volumes.isEmpty {
                source = .empty
                currentImages = []
                currentSourceURL = nil
                siblings = []
                errorMessage = "Folder is empty or has no supported content"
                return
            }
        }

        let finalIsDirectory = (try? targetURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

        do {
            loadingMessage = "Loading pages…"
            let loaded: ComicSource
            if finalIsDirectory {
                loaded = try await Task.detached(priority: .userInitiated) {
                    try FolderLoader.load(from: targetURL)
                }.value
            } else {
                loaded = try await CBZLoader.load(from: targetURL)
            }

            source = loaded
            currentSourceURL = targetURL
            if let siblingsToUse {
                siblings = siblingsToUse
            } else {
                siblings = await Self.scanSiblings(of: targetURL)
            }
            currentPageIndex = clampedRestoredIndex(for: targetURL, pageCount: loaded.pageCount)
            errorMessage = loaded.isEmpty ? "No images found" : nil
            await refreshImages()
        } catch {
            errorMessage = error.localizedDescription
            source = .empty
            currentImages = []
            currentSourceURL = nil
            siblings = []
            rootScopedURL?.stopAccessingSecurityScopedResource()
            rootScopedURL = nil
        }
    }

    private func isInsideRootScope(_ url: URL) -> Bool {
        guard let root = rootScopedURL else { return false }
        let rootPath = root.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == rootPath || target.hasPrefix(rootPath + "/")
    }

    private func isInsideCurrentTree(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path

        if let temp = currentTempDir {
            let tempPath = temp.standardizedFileURL.path
            if target == tempPath || target.hasPrefix(tempPath + "/") {
                return true
            }
        }

        return isInsideRootScope(url)
    }

    private func cleanupTempDir() {
        guard let dir = currentTempDir else { return }
        try? FileManager.default.removeItem(at: dir)
        currentTempDir = nil
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("panely-\(UUID().uuidString)", isDirectory: true)
    }

    private func savePosition() {
        guard let url = currentSourceURL else { return }
        let key = positionKey(for: url)
        var positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Int] ?? [:]
        positions[key] = currentPageIndex
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
    }

    private func restoredIndex(for url: URL) -> Int {
        let key = positionKey(for: url)
        let positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Int] ?? [:]
        return positions[key] ?? 0
    }

    private func positionKey(for url: URL) -> String {
        PositionKey.make(
            for: url,
            opened: openedSourceURL,
            tempRoot: currentTempDir
        )
    }

    private func clampedRestoredIndex(for url: URL, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        let restored = restoredIndex(for: url)
        let snapped = (restored / navigationStep) * navigationStep
        return min(max(snapped, 0), pageCount - 1)
    }

    private func refreshImages() async {
        // Cancel any in-flight lazy-load from a previous source/layout.
        lazyLoadTask?.cancel()
        lazyLoadTask = nil
        loadedPageIndices.removeAll()

        if layout.isContinuous {
            await refreshVerticalLazily()
        } else {
            await refreshPaged()
        }

        // Always clear the loading flag when refresh completes — covers the
        // toggleLayout-driven path where handleLayoutChange set it to true.
        // load() also clears via its own defer; double-clear is harmless.
        isLoading = false
        loadingMessage = ""
    }

    private func refreshPaged() async {
        let pages = visiblePages
        pageDimensions = []
        guard !pages.isEmpty else {
            currentImages = []
            return
        }

        var images: [NSImage] = []
        for page in pages {
            if let image = await loadVisibleImage(page) {
                images.append(image)
            }
        }
        currentImages = images

        schedulePreload()
    }

    /// Vertical mode: fetch all page dimensions concurrently (header-only,
    /// fast), populate the strip with same-sized placeholder NSImages so the
    /// layout is correct from frame 1, then load real images for the window
    /// around `currentPageIndex`. Subsequent loads are triggered by
    /// `setCurrentPageFromScroll` as the user scrolls.
    private func refreshVerticalLazily() async {
        let pages = source.pages
        guard !pages.isEmpty else {
            currentImages = []
            pageDimensions = []
            return
        }

        // 1. Fetch dimensions in bounded-concurrency chunks. Spawning one
        //    task per page on big folders (500+) blew through the cooperative
        //    pool and held a buffer per task; chunking caps concurrency at
        //    ~core count without losing throughput. Falls back to a generic
        //    portrait aspect for any page whose header read fails so layout
        //    still holds.
        let fallbackSize = CGSize(width: 1000, height: 1500)
        let maxConcurrent = Self.lazyConcurrencyLimit
        var dims = Array(repeating: fallbackSize, count: pages.count)
        for chunkStart in stride(from: 0, to: pages.count, by: maxConcurrent) {
            let chunkEnd = min(chunkStart + maxConcurrent, pages.count)
            await withTaskGroup(of: (Int, CGSize).self) { group in
                for i in chunkStart..<chunkEnd {
                    let page = pages[i]
                    group.addTask {
                        let size = (try? await ImageLoader.dimensions(for: page)) ?? fallbackSize
                        return (i, size)
                    }
                }
                for await (i, size) in group {
                    dims[i] = size
                }
            }
        }
        pageDimensions = dims

        // 2. Placeholders give ImageStackView the right frame for every slot.
        //    Use a visible neutral gray so unloaded slots look intentional
        //    instead of empty black voids during the brief load window.
        currentImages = dims.map { Self.makePlaceholder(size: $0) }

        // 3. Load the window around the restored page index.
        await ensureWindowLoaded(around: currentPageIndex)
    }

    /// Load real images for pages in `[index - radius ... index + radius]`
    /// that aren't already loaded. Concurrent with bounded fan-out.
    /// Updates `currentImages` once at the end so SwiftUI re-renders the
    /// strip a single time instead of per loaded image.
    private func ensureWindowLoaded(around index: Int) async {
        let lower = max(0, index - lazyWindowRadius)
        let upper = min(source.pageCount - 1, index + lazyWindowRadius)
        guard lower <= upper else { return }
        let needed = (lower...upper).filter { !loadedPageIndices.contains($0) }
        guard !needed.isEmpty else { return }

        await loadPagesBatched(needed)
    }

    private static func makePlaceholder(size: CGSize) -> NSImage {
        // drawingHandler is invoked lazily by AppKit when the image is actually
        // drawn, so this stays cheap (no upfront pixel allocation).
        NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.13, alpha: 1).setFill()
            rect.fill()
            return true
        }
    }

    private func cachedImage(for page: ComicPage) -> NSImage? {
        imageCache.object(forKey: page.id.uuidString as NSString)
    }

    private func cacheImage(_ image: NSImage, for page: ComicPage) {
        imageCache.setObject(image, forKey: page.id.uuidString as NSString)
    }

    private func loadVisibleImage(_ page: ComicPage) async -> NSImage? {
        if let cached = cachedImage(for: page) {
            return cached
        }
        do {
            let image = try await ImageLoader.load(page)
            cacheImage(image, for: page)
            return image
        } catch {
            errorMessage = "Failed to load \(page.displayName)"
            return nil
        }
    }

    private func preloadIfNeeded(_ page: ComicPage) async {
        if cachedImage(for: page) != nil { return }
        if Task.isCancelled { return }
        guard let image = try? await ImageLoader.load(page) else { return }
        // Don't pollute the cache with work the caller no longer wants —
        // important for rapid keyboard navigation where pages stream past
        // faster than decode completes.
        if Task.isCancelled { return }
        cacheImage(image, for: page)
    }

    private func pagesToPreload() -> [ComicPage] {
        guard !source.pages.isEmpty else { return [] }
        let step = navigationStep
        let visibleEnd = min(currentPageIndex + step, source.pageCount)
        let start = max(0, currentPageIndex - preloadRadius * step)
        let end = min(source.pageCount, visibleEnd + preloadRadius * step)

        var result: [ComicPage] = []
        let visibleRange = currentPageIndex..<visibleEnd
        for i in start..<end where !visibleRange.contains(i) {
            result.append(source.pages[i])
        }
        return result
    }

    private func schedulePreload() {
        preloadTask?.cancel()
        let pages = pagesToPreload()
        guard !pages.isEmpty else { return }

        preloadTask = Task { [weak self] in
            for page in pages {
                if Task.isCancelled { return }
                await self?.preloadIfNeeded(page)
            }
        }
    }

    nonisolated private static func scanSiblings(of url: URL) async -> [URL] {
        let volumes = await enumerateVolumes(in: url.deletingLastPathComponent())
        return volumes.isEmpty ? [url] : volumes
    }

    nonisolated private static func enumerateVolumes(in directory: URL) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }

            let volumes = contents.filter { candidate in
                let isDir = (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { return true }
                let ext = candidate.pathExtension.lowercased()
                return CBZLoader.supportedExtensions.contains(ext)
            }

            return volumes.sorted { a, b in
                a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        }.value
    }

    nonisolated private static func analyzeFolder(_ url: URL) async -> (hasImages: Bool, volumes: [URL]) {
        await Task.detached(priority: .userInitiated) {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return (false, [])
            }

            var hasImages = false
            var volumes: [URL] = []

            for entry in contents {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let ext = entry.pathExtension.lowercased()

                if isDir {
                    volumes.append(entry)
                } else if CBZLoader.supportedExtensions.contains(ext) {
                    volumes.append(entry)
                } else if FolderLoader.supportedExtensions.contains(ext) {
                    hasImages = true
                }
            }

            let sorted = volumes.sorted { a, b in
                a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }

            return (hasImages, sorted)
        }.value
    }
}
