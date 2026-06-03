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
        var types: [UTType] = [.folder, .zip]
        if let cbz = UTType(filenameExtension: "cbz") {
            types.append(cbz)
        }
        let request = FilePickerRequest(
            canChooseFiles: true,
            canChooseDirectories: true,
            allowedContentTypes: types,
            prompt: "Open"
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
        let request = FilePickerRequest(
            canChooseFiles: false,
            canChooseDirectories: true,
            prompt: "Select",
            message: "Select a folder to browse books from.",
            directoryURL: currentSourceURL?.deletingLastPathComponent()
        )

        guard let folderURL = filePicker.pickURL(request) else { return }
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

        // FSEvents auto-refresh is gated off in production (a busy / cloud-synced
        // root could storm tree re-scans and hang the app). The sidebar's manual
        // refresh button covers refresh until this is re-enabled with the
        // debounce verified on Release.
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
        let finished = page + navigationStep >= totalPages
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
