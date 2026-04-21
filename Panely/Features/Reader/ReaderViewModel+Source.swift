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
        explicitLibraryRootURL ?? currentSourceURL?.deletingLastPathComponent()
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

    // MARK: - Scope / temp helpers

    func isInsideRootScope(_ url: URL) -> Bool {
        guard let root = rootScopedURL else { return false }
        let rootPath = root.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == rootPath || target.hasPrefix(rootPath + "/")
    }

    func isInsideCurrentTree(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path

        if let temp = currentTempDir {
            let tempPath = temp.standardizedFileURL.path
            if target == tempPath || target.hasPrefix(tempPath + "/") {
                return true
            }
        }

        return isInsideRootScope(url)
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
