import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ReaderLoadIntent: Equatable {
    case open
    case librarySelection
    case favorite(innerPath: String?)
    case continueReading(relativePath: String?)
    /// Opening a page bookmark that lives in another book: land on
    /// `pageIndex` instead of the book's last-read position.
    case bookmark(innerPath: String?, pageIndex: Int)
    case previousVolume
    case nextVolumeFromEnd

    var preferredRelativePath: String? {
        switch self {
        case .favorite(let innerPath):
            return innerPath
        case .continueReading(let relativePath):
            return relativePath
        case .bookmark(let innerPath, _):
            return innerPath
        default:
            return nil
        }
    }

    /// Page to open on, overriding the restored reading position.
    var explicitPageIndex: Int? {
        if case .bookmark(_, let pageIndex) = self { return pageIndex }
        return nil
    }

    /// Continue Reading represents a precise persisted progress record. If
    /// that child disappears, opening an arbitrary first volume would resume
    /// the wrong book — and a page bookmark would land on the wrong page of
    /// it. Favorites keep their historical best-effort fallback.
    var requiresPreferredRelativePath: Bool {
        switch self {
        case .continueReading(let relativePath), .bookmark(let relativePath, _):
            return relativePath?.isEmpty == false
        default:
            return false
        }
    }

    var preservesLibraryRoot: Bool {
        self == .librarySelection
    }

    var restoresPosition: Bool {
        self != .nextVolumeFromEnd
    }

    var diagnosticName: String {
        switch self {
        case .open:
            "open"
        case .librarySelection:
            "librarySelection"
        case .favorite:
            "favorite"
        case .continueReading:
            "continueReading"
        case .bookmark:
            "bookmark"
        case .previousVolume:
            "previousVolume"
        case .nextVolumeFromEnd:
            "nextVolumeFromEnd"
        }
    }
}

/// Source entry points + lifecycle:
/// - the Open… / openURL / openLibraryURL / reload commands,
/// - library-root and sidebar-active URL derivation,
/// - scope helpers (`isInsideCurrentTree`, `isDirectory`, …),
/// - per-book position memory facades over `ReaderPositionStore`.
///
/// The actual `load(url:)` state machine lives in `ReaderViewModel+LoadPipeline`;
/// volume navigation in `ReaderViewModel+Volumes`.
extension ReaderViewModel {

    // MARK: - Library root resolution

    var libraryRootURL: URL? {
        if let explicit = explicitLibraryRootURL { return explicit }
        // Prefer the originally opened file's parent over `currentSourceURL`.
        // For zip-in-zip, `currentSourceURL` points into the extracted temp
        // dir, whose contents already appear in the Volumes section — using
        // it as the library root would duplicate that listing in the Files
        // tree. `openedSourceURL` keeps the user's actual library location
        // visible while Volumes covers the in-archive volumes.
        //
        // For a directory entry (drag-drop, Open With on a folder, picking a
        // folder via Open…) use the folder itself, not its parent. The
        // sandbox grant from Powerbox is scoped to exactly that URL, so the
        // parent is unreadable — `contentsOfDirectory` silently fails and
        // the Files tree shows the misleading "No books to show" prompt.
        if let opened = openedSourceURL {
            let isDir = (try? opened.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return isDir ? opened : opened.deletingLastPathComponent()
        }
        return currentSourceURL?.deletingLastPathComponent()
    }

    var sidebarActiveURL: URL? {
        pendingSourceURL ?? currentSourceURL
    }

    // MARK: - Opening new sources

    func openSource() {
        var types: [UTType] = [.folder, .zip]
        types += ["cbz", "cbr", "rar"].compactMap { UTType(filenameExtension: $0) }
        let request = FilePickerRequest(
            canChooseFiles: true,
            canChooseDirectories: true,
            allowedContentTypes: types,
            prompt: String(localized: "Open")
        )

        guard let url = filePicker.pickURL(request) else { return }
        AppLog.info(
            .load,
            "Open panel selected",
            metadata: ["source": "\(DiagnosticRedactor.describe(url))"]
        )
        recentItems.record(url, title: displayTitle(for: url))
        Task { await load(url: url) }
    }

    func openURL(_ url: URL) {
        AppLog.info(
            .load,
            "Open URL requested",
            metadata: ["source": "\(DiagnosticRedactor.describe(url))"]
        )
        recentItems.record(url, title: displayTitle(for: url))
        Task { await load(url: url) }
    }

    func reloadCurrentSource() {
        guard let request = reloadRequest() else { return }
        AppLog.info(
            .load,
            "Reload current source requested",
            metadata: [
                "source": "\(DiagnosticRedactor.describe(request.url))",
                "innerPath": "\(request.innerPath ?? "")",
            ]
        )
        Task {
            await load(
                url: request.url,
                knownSiblings: request.knownSiblings,
                intent: request.innerPath.map { .favorite(innerPath: $0) } ?? .open
            )
        }
    }

    func clearSourceChangeNotice() {
        sourceChangedOnDisk = false
        sourceChangeMessage = nil
    }

    func markSourceChangedOnDisk() {
        guard hasSource else { return }
        sourceChangedOnDisk = true
        sourceChangeMessage = String(localized: "The current book changed on disk.")
        Task { await refreshContinueReadingAvailability() }
    }

    func openLibraryURL(_ url: URL) {
        AppLog.info(
            .library,
            "Library URL selected",
            metadata: ["source": "\(DiagnosticRedactor.describe(url))"]
        )
        recentItems.record(url, title: displayTitle(for: url))
        Task { await load(url: url, intent: .librarySelection) }
    }

    /// Ask the user for a folder to browse. `forVolumeNavigation` is the
    /// "this book was opened on its own, so its neighbours are unreadable"
    /// case — same panel, but worded around stepping between books and
    /// anchored on the folder the open book actually lives in.
    func requestFolderAccess(forVolumeNavigation: Bool = false) {
        let bookURL = tempDir.isActive ? openedSourceURL : currentSourceURL
        let request = FilePickerRequest(
            canChooseFiles: false,
            canChooseDirectories: true,
            prompt: forVolumeNavigation ? String(localized: "Allow") : String(localized: "Select"),
            message: forVolumeNavigation
                ? String(localized: "Allow access to this folder so Panely can open the next and previous books in it.")
                : String(localized: "Select a folder to browse books from."),
            directoryURL: bookURL?.deletingLastPathComponent()
        )

        guard let folderURL = filePicker.pickURL(request) else { return }
        AppLog.info(
            .library,
            "Folder access granted",
            metadata: ["source": "\(DiagnosticRedactor.describe(folderURL))"]
        )

        guard libraryScope.acquire(folderURL) else {
            errorMessage = String(localized: "Could not access selected folder.")
            AppLog.error(
                .library,
                "Folder access failed",
                metadata: ["source": "\(DiagnosticRedactor.describe(folderURL))"]
            )
            return
        }

        recentItems.record(folderURL, title: displayTitle(for: folderURL))
        explicitLibraryRootURL = folderURL
        dismissVolumeNotice()

        Task {
            if let current = currentSourceURL, libraryScope.contains(current) {
                // Climb from the book rather than listing the picked folder:
                // the user may have granted a folder a few levels above it,
                // and volume stepping wants the book's own series level.
                siblings = await FolderResolver.nearestSeriesVolumes(of: current, boundedBy: folderURL)
                refreshSiblingFolderReadability(for: current)
            }
            libraryRefreshToken = UUID()
            syncLibraryWatcher()
        }
    }

    /// A folder the user has already granted — a recent folder or the
    /// remembered library root — that contains `url`. The deepest match wins,
    /// so a file inside a previously opened series folder re-roots on that
    /// series rather than on the whole library above it.
    ///
    /// A book file opened on its own (Finder, Open…, a favorite) carries a
    /// sandbox grant for that one file only; its folder, and therefore its
    /// sibling volumes, stay unreadable. Reusing an earlier folder grant is
    /// what makes "allow this folder once" stick across launches.
    func rememberedFolderGrant(containing url: URL) -> URL? {
        let target = url.standardizedFileURL
        let candidates = recentItems.items
            .filter {
                $0.isDirectory
                    && $0.path != target.path
                    && URL(fileURLWithPath: $0.path).isAncestor(of: target)
            }
            .sorted { $0.path.count > $1.path.count }
        for item in candidates {
            guard let folder = recentItems.resolve(item),
                  folder.path != target.path,
                  folder.isAncestor(of: target) else { continue }
            return folder
        }
        if let folder = lastLibraryRoot.peek()?.standardizedFileURL,
           folder.path != target.path,
           folder.isAncestor(of: target) {
            return folder
        }
        return nil
    }

    /// Record whether the open book's folder can be listed. Checked once per
    /// load / folder grant instead of on every render — the toolbar reads the
    /// result to decide whether volume stepping needs a folder grant first.
    func refreshSiblingFolderReadability(for bookURL: URL) {
        let parent = bookURL.deletingLastPathComponent()
        siblingFolderUnreadable = !FileManager.default.isReadableFile(atPath: parent.path)
    }

    /// Force a re-scan of the library file tree. Bumping the token changes
    /// the sidebar's `.task(id:)` key, which re-runs `LibrarySidebarModel.reload`
    /// and picks up files added/removed on disk since the last scan. Driven
    /// both by the sidebar's manual refresh button and by `syncLibraryWatcher`'s
    /// on-disk change callback.
    func refreshLibraryTree() {
        libraryRefreshToken = UUID()
        Task { await refreshContinueReadingAvailability() }
    }

    /// (Re)point the recursive directory watcher at the current library root.
    /// No-op when the root is unchanged. Only watches a root we hold
    /// directory-level access to (the security-scoped folder); single-file
    /// opens — whose derived root is an unreadable parent — are skipped, since
    /// the tree shows the access prompt there anyway and FSEvents on an
    /// unreadable path would just fail.
    func syncLibraryWatcher() {
        let root = libraryRootURL
        guard watchedLibraryRootURL?.standardizedFileURL != root?.standardizedFileURL else { return }

        libraryDirectoryWatcher?.stopWatching()
        libraryDirectoryWatcher = nil

        guard let root,
              isDirectory(root),
              libraryScope.contains(root) else {
            watchedLibraryRootURL = nil
            return
        }

        watchedLibraryRootURL = root

        // Remember this root so the next launch reopens it instead of starting
        // empty. Runs here because this is the one place a readable, scoped
        // library directory settles (open, folder-pick, and launch-restore all
        // funnel through here). Independent of the auto-refresh watcher below.
        lastLibraryRoot.save(root)

        // FSEvents auto-refresh, behind a flag so tests and previews can opt out.
        // The 1.5s debounce below keeps a busy / cloud-synced root from storming
        // full tree re-scans. (This was briefly disabled while chasing a Release
        // freeze that turned out to be an unrelated SwiftUI update loop in the
        // viewer's fit application — see AppKitImageScroller.applyFit.)
        guard libraryAutoRefreshEnabled else { return }

        let watcher = makeLibraryDirectoryWatcher()
        libraryDirectoryWatcher = watcher
        watcher.startWatching(root: root) { [weak self] in
            // Debounce: only refresh once the folder goes quiet, so a busy /
            // cloud-synced root can't storm full tree re-scans.
            self?.libraryRefreshDebouncer.schedule {
                self?.refreshLibraryTree()
            }
        }
    }

    /// On a cold launch with nothing opened, reopen the last browsed library
    /// folder so the user doesn't have to pick it every session. Never clobbers
    /// a file the app was launched with (Open With / `onOpenURL`) or an
    /// in-flight load — those set a source/loading flag the guards bail on.
    func restoreLastLibraryRootIfNeeded() {
        guard reopenLastFolderOnLaunch,
              libraryRootURL == nil,
              currentSourceURL == nil,
              pendingSourceURL == nil,
              openedSourceURL == nil,
              !isLoading,
              let url = lastLibraryRoot.restore(),
              libraryScope.acquire(url)
        else { return }

        explicitLibraryRootURL = url
        libraryRefreshToken = UUID()
        syncLibraryWatcher()
        AppLog.info(
            .library,
            "Restored last library root",
            metadata: ["source": "\(DiagnosticRedactor.describe(url))"]
        )
    }

    func stopLibraryWatcher() {
        libraryDirectoryWatcher?.stopWatching()
        libraryDirectoryWatcher = nil
        watchedLibraryRootURL = nil
    }

    func displayTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Scope helpers
    //
    // Visible to `ReaderViewModel+LoadPipeline` (same class, different file)
    // so the pipeline can ask "did the user open a new book or stay in the
    // same library scope?" without duplicating the logic.

    func isInsideCurrentTree(_ url: URL) -> Bool {
        if tempDir.contains(url) { return true }
        return libraryScope.contains(url)
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    func libraryRootURLIfItContains(_ url: URL) -> URL? {
        guard let root = libraryRootURL,
              root.isAncestor(of: url) else {
            return nil
        }
        return root
    }

    // MARK: - Per-book position memory
    //
    // Key derivation lives on `ReaderPositionStore` — these are thin facades
    // that fill in the current opened/temp context.

    /// Position key for `url`. Nil-safe wrapper; `ReaderPositionStore` is the
    /// source of truth for how keys are built.
    func positionKey(for url: URL) -> String {
        positions.primaryKey(for: url, opened: openedSourceURL, tempRoot: tempDir.url)
    }

    /// Identifier for the series the currently-open book belongs to (parent
    /// folder, or the opened archive for zip-in-zip), or `nil` when nothing is
    /// open. Drives the per-series scope: zoom carry-over within a series and
    /// the persisted direction/layout/fitMode memory. Empty string when there
    /// is no source so the viewer's `seriesIdentity` prop has a stable value.
    var seriesIdentity: String {
        ReaderSeriesIdentity.make(
            for: currentSourceURL,
            opened: openedSourceURL,
            tempRoot: tempDir.url
        ) ?? ""
    }

    /// Restore the current series' remembered direction/layout/fitMode (if it
    /// has any) onto the global preferences, so opening a book reads the way
    /// that series was last read. Writes `preferences.*` *directly* — not via
    /// the write-through setters — so restoring never re-stamps the series
    /// store. A series with no saved override (first time opened) leaves the
    /// global default untouched, making it that series' starting point.
    ///
    /// Call after `currentSourceURL` is set (so `seriesIdentity` resolves) and
    /// before the restored page index is computed (so the spread snap uses the
    /// final layout).
    func applySeriesPreferences() {
        let id = seriesIdentity
        guard !id.isEmpty else { return }
        if let direction = seriesPreferences.direction(forSeries: id) {
            preferences.direction = direction
        }
        if let layout = seriesPreferences.layout(forSeries: id) {
            preferences.layout = layout
        }
        if let fitMode = seriesPreferences.fitMode(forSeries: id) {
            preferences.fitMode = fitMode
        }
    }

    /// Schedule a debounced save for the current page. Called from the
    /// `currentPageIndex` didSet, so this fires once per page change — even
    /// during 60 Hz vertical scroll the store coalesces into a single write.
    func savePosition() {
        persistPosition(immediate: false)
    }

    /// Synchronous flush used by the app-terminate observer.
    func flushPositionImmediately() {
        persistPosition(immediate: true)
    }

    /// Writes the current page to both the position store (exact restore) and
    /// the reading-progress store (badges / Continue Reading). `immediate`
    /// picks the synchronous flush over the debounced save — the only thing
    /// that differs between the two entry points above.
    private func persistPosition(immediate: Bool) {
        guard let url = currentSourceURL else { return }
        let opened = openedSourceURL
        let tempRoot = tempDir.url
        let page = currentPageIndex

        if immediate {
            positions.flushImmediately(for: url, opened: opened, tempRoot: tempRoot, pageIndex: page)
        } else {
            positions.savePosition(for: url, opened: opened, tempRoot: tempRoot, pageIndex: page)
        }

        guard totalPages > 0 else { return }
        let finished = SpreadCalculator.nextStart(
            from: page,
            pageCount: totalPages,
            step: navigationStep,
            coverAlone: spreadCoverAlone
        ) == nil
        if immediate {
            readingProgress.flushImmediately(for: url, opened: opened, tempRoot: tempRoot, page: page, total: totalPages, finished: finished)
        } else {
            readingProgress.record(for: url, opened: opened, tempRoot: tempRoot, page: page, total: totalPages, finished: finished)
        }
    }

    func restoredIndex(for url: URL) -> Int {
        positions.restoredIndex(for: url, opened: openedSourceURL, tempRoot: tempDir.url)
    }

    func clampedRestoredIndex(for url: URL, pageCount: Int) -> Int {
        spreadStart(containing: restoredIndex(for: url), pageCount: pageCount)
    }

    /// Snap `index` to its spread's start under the current layout and
    /// offset. `SpreadCalculator` clamps out-of-range indices to the final
    /// spread, so the last spread stays reachable (no off-by-one snap back to
    /// the previous spread).
    func spreadStart(containing index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return SpreadCalculator.spread(
            containing: index,
            pageCount: pageCount,
            step: navigationStep,
            coverAlone: spreadCoverAlone
        ).lowerBound
    }
}
