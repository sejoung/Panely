import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ReaderLoadIntent: Equatable {
    case open
    case librarySelection
    case favorite(innerPath: String?)
    case previousVolume
    case nextVolumeFromEnd

    var preferredRelativePath: String? {
        guard case .favorite(let innerPath) = self else { return nil }
        return innerPath
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
        sourceChangeMessage = "The current book changed on disk."
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
        AppLog.info(
            .library,
            "Folder access granted",
            metadata: ["source": "\(DiagnosticRedactor.describe(folderURL))"]
        )

        libraryScope.acquire(folderURL)

        recentItems.record(folderURL, title: displayTitle(for: folderURL))
        explicitLibraryRootURL = folderURL

        Task {
            let volumes = await FolderResolver.enumerateVolumes(in: folderURL)
            if let current = currentSourceURL, libraryScope.contains(current) {
                siblings = volumes.isEmpty ? [current] : volumes
            }
            libraryRefreshToken = UUID()
            syncLibraryWatcher()
        }
    }

    /// Force a re-scan of the library file tree. Bumping the token changes
    /// the sidebar's `.task(id:)` key, which re-runs `LibrarySidebarModel.reload`
    /// and picks up files added/removed on disk since the last scan. Driven
    /// both by the sidebar's manual refresh button and by `syncLibraryWatcher`'s
    /// on-disk change callback.
    func refreshLibraryTree() {
        libraryRefreshToken = UUID()
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

        guard let root,
              isDirectory(root),
              libraryScope.contains(root) else {
            libraryDirectoryWatcher = nil
            watchedLibraryRootURL = nil
            return
        }

        let watcher = libraryDirectoryWatcher ?? makeLibraryDirectoryWatcher()
        libraryDirectoryWatcher = watcher
        watchedLibraryRootURL = root
        watcher.startWatching(root: root) { [weak self] in
            self?.refreshLibraryTree()
        }

        // Remember this root so the next launch reopens it instead of starting
        // empty. Runs here because this is the one place a readable, scoped
        // library directory settles (open, folder-pick, and launch-restore all
        // funnel through here).
        lastLibraryRoot.save(root)
    }

    /// On a cold launch with nothing opened, reopen the last browsed library
    /// folder so the user doesn't have to pick it every session. Never clobbers
    /// a file the app was launched with (Open With / `onOpenURL`) or an
    /// in-flight load — those set a source/loading flag the guards bail on.
    func restoreLastLibraryRootIfNeeded() {
        guard libraryRootURL == nil,
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

    /// Schedule a debounced save for the current page. Called from the
    /// `currentPageIndex` didSet, so this fires once per page change — even
    /// during 60 Hz vertical scroll the store coalesces into a single write.
    func savePosition() {
        guard let url = currentSourceURL else { return }
        positions.savePosition(
            for: url,
            opened: openedSourceURL,
            tempRoot: tempDir.url,
            pageIndex: currentPageIndex
        )
        guard totalPages > 0 else { return }
        readingProgress.record(
            for: url,
            opened: openedSourceURL,
            tempRoot: tempDir.url,
            page: currentPageIndex,
            total: totalPages,
            finished: currentPageIndex + navigationStep >= totalPages
        )
    }

    /// Synchronous flush used by the app-terminate observer.
    func flushPositionImmediately() {
        guard let url = currentSourceURL else { return }
        positions.flushImmediately(
            for: url,
            opened: openedSourceURL,
            tempRoot: tempDir.url,
            pageIndex: currentPageIndex
        )
        guard totalPages > 0 else { return }
        readingProgress.flushImmediately(
            for: url,
            opened: openedSourceURL,
            tempRoot: tempDir.url,
            page: currentPageIndex,
            total: totalPages,
            finished: currentPageIndex + navigationStep >= totalPages
        )
    }

    func restoredIndex(for url: URL) -> Int {
        positions.restoredIndex(for: url, opened: openedSourceURL, tempRoot: tempDir.url)
    }

    func clampedRestoredIndex(for url: URL, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        let restored = restoredIndex(for: url)
        let step = navigationStep
        let snapped = (restored / step) * step
        // Highest valid step-aligned start: for 100-page double-page mode,
        // that's index 98 (spread 99–100). The previous formula clamped to
        // `pageCount - 1` (=99), which then rounded back down via the step
        // snap and stranded the reader one spread short of where they left
        // off. Use the last step-aligned index instead so the final spread
        // is reachable.
        let maxAligned = max(0, ((pageCount - 1) / step) * step)
        return min(max(snapped, 0), maxAligned)
    }
}
