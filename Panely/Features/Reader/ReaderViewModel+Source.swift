import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Source loading (folder / archive), volume/sibling navigation, library
/// root handling, and per-book position memory. Anything that touches disk
/// or security-scoped URLs lives here.
extension ReaderViewModel {

    // MARK: - Volume / sibling navigation

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

    /// Volumes to surface as a dedicated sidebar section. Only populated for
    /// zip-in-zip (when the volumes live inside `currentTempDir` and are not
    /// visible in the Files tree). For folder/cbz series the volumes already
    /// appear in the tree under the parent folder, so a separate section
    /// would just duplicate what's already on screen.
    var sidebarVolumes: [URL] {
        guard hasMultipleVolumes, currentTempDir != nil else { return [] }
        return siblings
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

    // MARK: - End-of-volume card

    /// True when the user is on the final page/spread — i.e., when `next()`
    /// would no-op. Mirrors `next()`'s guard exactly so the card appears
    /// precisely when forward navigation runs out, in both paged and vertical
    /// layouts.
    var isAtLastPage: Bool {
        let count = source.pageCount
        guard count > 0 else { return false }
        return currentPageIndex + navigationStep >= count
    }

    /// Drives the end-of-volume card. Visible only when there's a next sibling
    /// to advance to — last volume in a series shows nothing rather than a
    /// "completion" toast (kept simple for v1).
    var showsEndOfVolumeCard: Bool {
        isAtLastPage && canGoNextVolume
    }

    /// Filename (no extension) of the next sibling. Used as the card's
    /// preview label so users see *which* volume they'd advance to.
    var nextVolumeDisplayName: String? {
        guard canGoNextVolume, let idx = currentSiblingIndex else { return nil }
        return siblings[idx + 1].deletingPathExtension().lastPathComponent
    }

    /// Restart the current volume from page 1. Used by the card's secondary
    /// action so users can re-read without picking from the slider.
    func restartCurrentVolume() {
        jump(toPageNumber: 1)
    }

    /// Drives the previous-volume card. Asymmetric vs `showsEndOfVolumeCard`
    /// on purpose: that card auto-appears whenever you're at the last page,
    /// but this one only surfaces after the user has signaled intent (via
    /// `goBackward()`). Otherwise opening Vol N (which lands on page 0 on
    /// first read) would noisily prompt about Vol N-1 every time.
    var showsPreviousVolumeCard: Bool {
        wantsPreviousVolumePrompt && canGoPreviousVolume
    }

    /// Filename (no extension) of the previous sibling.
    var previousVolumeDisplayName: String? {
        guard canGoPreviousVolume, let idx = currentSiblingIndex else { return nil }
        return siblings[idx - 1].deletingPathExtension().lastPathComponent
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

    func displayTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Main load pipeline

    func load(url: URL, knownSiblings: [URL]? = nil) async {
        preloadTask?.cancel()

        // Any new book load — explicit, via prev/next volume, or via library
        // — resets the prev-volume cue. Without this, opening Vol N+1 after
        // dismissing Vol N's card by jumping pages could carry the stale flag
        // when the new book's saved position lands at index 0 (didSet on
        // currentPageIndex doesn't fire when oldValue == newValue == 0).
        wantsPreviousVolumePrompt = false

        // Each load captures its own epoch and re-checks after every await.
        // If a newer load has bumped the counter, this one bails out without
        // overwriting the newer load's state. The defer is also epoch-aware
        // so an interrupted earlier load doesn't clear `isLoading` while the
        // later load is still in flight.
        loadEpoch &+= 1
        let myEpoch = loadEpoch

        isLoading = true
        loadingMessage = "Opening…"
        defer {
            if myEpoch == loadEpoch {
                isLoading = false
                loadingMessage = ""
            }
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
        } else if currentTempDir != nil && !isInsideTempDir(url) {
            // Inside the library scope but outside the active temp dir —
            // user is switching to a different book (or re-opening the
            // same zip-in-zip after a library-root change). Drop the stale
            // temp so the extraction block below re-runs against the new
            // URL; without this, the original extraction is reused and we
            // try to load the outer archive directly.
            cleanupTempDir()
            openedSourceURL = url
        }

        var targetURL = url
        var siblingsToUse = knownSiblings

        if currentTempDir == nil {
            let ext = url.pathExtension.lowercased()
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDir && CBZLoader.supportedExtensions.contains(ext) {
                loadingMessage = "Analyzing archive…"
                if let hasNested = try? await CBZLoader.hasNestedArchives(at: url) {
                    guard myEpoch == loadEpoch else { return }
                    if hasNested {
                        loadingMessage = "Extracting archive…"
                        let tempDir = Self.makeTempDir()
                        do {
                            try await CBZLoader.extractAll(from: url, to: tempDir)
                            guard myEpoch == loadEpoch else {
                                // Newer load is in flight; don't keep the
                                // tempDir we just created — it would leak.
                                try? FileManager.default.removeItem(at: tempDir)
                                return
                            }
                            currentTempDir = tempDir
                            targetURL = tempDir
                        } catch {
                            try? FileManager.default.removeItem(at: tempDir)
                            guard myEpoch == loadEpoch else { return }
                            errorMessage = "Failed to extract archive: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }

        let isDirectory = (try? targetURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

        if isDirectory {
            loadingMessage = "Scanning folder…"
            let (hasImages, volumes) = await Self.analyzeFolder(targetURL)
            guard myEpoch == loadEpoch else { return }

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
            guard myEpoch == loadEpoch else { return }

            source = loaded
            currentSourceURL = targetURL
            if let siblingsToUse {
                siblings = siblingsToUse
            } else if siblings.contains(where: {
                $0.standardizedFileURL == targetURL.standardizedFileURL
            }) {
                // Already in the active siblings group (sidebar volume click,
                // re-opening the same book, etc.). Keep them as-is and skip
                // the disk enumeration — saves a directory scan per click in
                // large series.
            } else {
                siblings = await Self.scanSiblings(of: targetURL)
                guard myEpoch == loadEpoch else { return }
            }
            currentPageIndex = clampedRestoredIndex(for: targetURL, pageCount: loaded.pageCount)
            errorMessage = loaded.isEmpty ? "No images found" : nil
            await refreshImages()
        } catch {
            guard myEpoch == loadEpoch else { return }
            errorMessage = error.localizedDescription
            source = .empty
            currentImages = []
            currentSourceURL = nil
            siblings = []
            rootScopedURL?.stopAccessingSecurityScopedResource()
            rootScopedURL = nil
        }
    }

    // MARK: - Scope / temp helpers

    func isInsideRootScope(_ url: URL) -> Bool {
        guard let root = rootScopedURL else { return false }
        let rootPath = root.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == rootPath || target.hasPrefix(rootPath + "/")
    }

    func isInsideCurrentTree(_ url: URL) -> Bool {
        if isInsideTempDir(url) { return true }
        return isInsideRootScope(url)
    }

    func isInsideTempDir(_ url: URL) -> Bool {
        guard let temp = currentTempDir else { return false }
        let tempPath = temp.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == tempPath || target.hasPrefix(tempPath + "/")
    }

    func cleanupTempDir() {
        guard let dir = currentTempDir else { return }
        try? FileManager.default.removeItem(at: dir)
        currentTempDir = nil
    }

    static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("panely-\(UUID().uuidString)", isDirectory: true)
    }

    /// Sweep `panely-*` directories left behind by a prior session that
    /// crashed or was force-quit before `cleanupTempDir()` could run. A
    /// single zip-in-zip extraction can be hundreds of megabytes, and macOS
    /// only sweeps the sandbox tmp opportunistically (not on every launch),
    /// so leftovers can quietly accumulate. Safe to call only at startup —
    /// it makes no attempt to spare an in-flight extraction.
    nonisolated static func cleanupStaleTempDirs() {
        let tmpRoot = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmpRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix("panely-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Per-book position memory

    /// Scheduled from the `currentPageIndex` didSet. Debounces the actual
    /// UserDefaults write so that dragging through a vertical strip at 60 Hz
    /// doesn't thrash the positions dictionary. A quick quit-during-scroll
    /// can lose ~300 ms of progress; flushPositionImmediately() is called on
    /// app termination to cover that window.
    func savePosition() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.writePositionNow()
        }
    }

    /// Synchronous write used by the debounced path (after the sleep) and by
    /// the app-terminate flush.
    func flushPositionImmediately() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        writePositionNow()
    }

    private func writePositionNow() {
        guard let url = currentSourceURL else { return }
        let key = positionKey(for: url)
        var positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Int] ?? [:]
        positions[key] = currentPageIndex
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
    }

    func restoredIndex(for url: URL) -> Int {
        let key = positionKey(for: url)
        let positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Int] ?? [:]
        return positions[key] ?? 0
    }

    func positionKey(for url: URL) -> String {
        PositionKey.make(
            for: url,
            opened: openedSourceURL,
            tempRoot: currentTempDir
        )
    }

    func clampedRestoredIndex(for url: URL, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        let restored = restoredIndex(for: url)
        let snapped = (restored / navigationStep) * navigationStep
        return min(max(snapped, 0), pageCount - 1)
    }

    // MARK: - Off-main folder scanners

    nonisolated static func scanSiblings(of url: URL) async -> [URL] {
        let volumes = await enumerateVolumes(in: url.deletingLastPathComponent())
        return volumes.isEmpty ? [url] : volumes
    }

    nonisolated static func enumerateVolumes(in directory: URL) async -> [URL] {
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

    nonisolated static func analyzeFolder(_ url: URL) async -> (hasImages: Bool, volumes: [URL]) {
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
