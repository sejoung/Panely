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
}

private enum ReaderLoadError: LocalizedError {
    case extractionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let error):
            return "Failed to extract archive: \(error.localizedDescription)"
        }
    }
}

private enum FolderTargetResolution {
    case book(URL, siblings: [URL]?)
    case empty
}

/// Source loading — Open dialogs, the main `load(url:)` pipeline, security
/// scope acquisition, and the off-main folder/archive scanners. Volume
/// navigation (counters, sibling stepping, end-of-volume cards) lives in
/// `ReaderViewModel+Volumes.swift`.
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

    func openLibraryURL(_ url: URL) {
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

        libraryScope.acquire(folderURL)

        recentItems.record(folderURL, title: displayTitle(for: folderURL))
        explicitLibraryRootURL = folderURL

        Task {
            let volumes = await Self.enumerateVolumes(in: folderURL)
            if let current = currentSourceURL, libraryScope.contains(current) {
                siblings = volumes.isEmpty ? [current] : volumes
            }
            libraryRefreshToken = UUID()
        }
    }

    func displayTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Main load pipeline

    func load(
        url: URL,
        knownSiblings: [URL]? = nil,
        intent: ReaderLoadIntent = .open
    ) async {
        let myEpoch = startLoad()
        let preservedLibraryRootURL = intent.preservesLibraryRoot
            ? libraryRootURLIfItContains(url)
            : nil
        defer {
            if myEpoch == loadEpoch {
                isLoading = false
                loadingMessage = ""
            }
        }

        prepareScope(for: url, preservedLibraryRootURL: preservedLibraryRootURL)

        var targetURL = url
        var siblingsToUse = knownSiblings

        do {
            guard let archiveTarget = try await resolveArchiveTarget(for: targetURL, epoch: myEpoch) else {
                return
            }
            targetURL = targetByApplyingPreferredRelativePath(
                to: archiveTarget,
                applyingPreferredRelativePath: intent.preferredRelativePath
            )

            guard let folderTarget = await resolveFolderTarget(for: targetURL, epoch: myEpoch) else {
                return
            }

            switch folderTarget {
            case .book(let url, let siblings):
                targetURL = url
                siblingsToUse = siblings ?? siblingsToUse
            case .empty:
                clearLoadedSource(message: "Folder is empty or has no supported content")
                return
            }

            loadingMessage = "Loading pages…"
            let loaded = try await loadComicSource(from: targetURL)
            guard myEpoch == loadEpoch else { return }

            let didApply = await applyLoadedSource(
                loaded,
                targetURL: targetURL,
                siblingsToUse: siblingsToUse,
                restorePosition: intent.restoresPosition,
                epoch: myEpoch
            )
            guard didApply else { return }
            errorMessage = loaded.isEmpty ? "No images found" : nil
            await refreshImages()
        } catch {
            guard myEpoch == loadEpoch else { return }
            clearLoadedSource(message: error.localizedDescription)
            libraryScope.release()
        }
    }

    private func startLoad() -> Int {
        imageLoader.cancelPreload()

        // Any new book load — explicit, via prev/next volume, or via library
        // — resets the prev-volume cue. Without this, opening Vol N+1 after
        // dismissing Vol N's card by jumping pages could carry the stale flag
        // when the new book's saved position lands at index 0 (didSet on
        // currentPageIndex doesn't fire when oldValue == newValue == 0).
        wantsPreviousVolumePrompt = false

        loadEpoch &+= 1
        isLoading = true
        loadingMessage = "Opening…"
        return loadEpoch
    }

    private func prepareScope(for url: URL, preservedLibraryRootURL: URL?) {
        if !isInsideCurrentTree(url) {
            tempDir.cleanup()
            libraryScope.acquire(url)
            explicitLibraryRootURL = preservedLibraryRootURL
            openedSourceURL = url
        } else if tempDir.isActive && !tempDir.contains(url) {
            // Inside the library scope but outside the active temp dir —
            // user is switching to a different book (or re-opening the
            // same zip-in-zip after a library-root change). Drop the stale
            // temp so the extraction block below re-runs against the new
            // URL; without this, the original extraction is reused and we
            // try to load the outer archive directly.
            tempDir.cleanup()
            if let preservedLibraryRootURL {
                explicitLibraryRootURL = preservedLibraryRootURL
            }
            openedSourceURL = url
        }
    }

    private func resolveArchiveTarget(for url: URL, epoch: Int) async throws -> URL? {
        guard !tempDir.isActive,
              isSupportedArchive(url) else {
            return url
        }

        loadingMessage = "Analyzing archive…"
        guard let hasNested = try? await CBZLoader.hasNestedArchives(at: url) else {
            return url
        }
        guard epoch == loadEpoch else { return nil }
        guard hasNested else { return url }

        return try await resolveNestedArchiveTarget(for: url, epoch: epoch)
    }

    private func resolveNestedArchiveTarget(for url: URL, epoch: Int) async throws -> URL? {
        // Cache hit fast path — same archive (same path + size + mtime)
        // reuses the previous extraction so reopen is instant. Edits to the
        // source bump mtime → new key → automatic re-extraction.
        let extractionCache = dependencies.extractionCache
        let key = extractionCache.cacheKey(for: url)
        if let key,
           let cached = extractionCache.cachedEntry(forKey: key) {
            tempDir.adopt(cached)
            return cached
        }

        loadingMessage = "Extracting archive…"
        let candidate = key.map { extractionCache.makeCachedCandidate(forKey: $0) }
            ?? ReaderTempDirectory.makeSessionCandidate()

        do {
            try await CBZLoader.extractAll(from: url, to: candidate)
            guard epoch == loadEpoch else {
                try? FileManager.default.removeItem(at: candidate)
                return nil
            }
            tempDir.adopt(candidate)
            if key != nil {
                Task.detached(priority: .background) {
                    extractionCache.enforceBudget()
                }
            }
            return candidate
        } catch {
            try? FileManager.default.removeItem(at: candidate)
            throw ReaderLoadError.extractionFailed(error)
        }
    }

    private func targetByApplyingPreferredRelativePath(
        to targetURL: URL,
        applyingPreferredRelativePath relativePath: String?
    ) -> URL {
        guard let relativePath,
              !relativePath.isEmpty,
              tempDir.isActive,
              let root = tempDir.url else {
            return targetURL
        }

        let preferred = root
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard root.isAncestor(of: preferred),
              FileManager.default.fileExists(atPath: preferred.path) else {
            return targetURL
        }
        return preferred
    }

    private func resolveFolderTarget(for url: URL, epoch: Int) async -> FolderTargetResolution? {
        guard isDirectory(url) else {
            return .book(url, siblings: nil)
        }

        loadingMessage = "Scanning folder…"
        let (hasImages, volumes) = await Self.analyzeFolder(url)
        guard epoch == loadEpoch else { return nil }

        if !hasImages && !volumes.isEmpty {
            guard let first = volumes.first else { return .empty }
            return .book(first, siblings: volumes)
        }

        if !hasImages {
            return .empty
        }

        return .book(url, siblings: nil)
    }

    private func loadComicSource(from url: URL) async throws -> ComicSource {
        if isDirectory(url) {
            return try await Task.detached(priority: .userInitiated) {
                try FolderLoader.load(from: url)
            }.value
        }
        return try await CBZLoader.load(from: url)
    }

    private func applyLoadedSource(
        _ loaded: ComicSource,
        targetURL: URL,
        siblingsToUse: [URL]?,
        restorePosition: Bool,
        epoch: Int
    ) async -> Bool {
        let resolvedSiblings: [URL]?
        if let siblingsToUse {
            resolvedSiblings = siblingsToUse
        } else if siblings.contains(where: {
            $0.standardizedFileURL == targetURL.standardizedFileURL
        }) {
            resolvedSiblings = nil
        } else {
            resolvedSiblings = await Self.scanSiblings(of: targetURL)
            guard epoch == loadEpoch else { return false }
        }

        source = loaded
        currentSourceURL = targetURL
        if let resolvedSiblings {
            siblings = resolvedSiblings
        }
        currentPageIndex = restorePosition
            ? clampedRestoredIndex(for: targetURL, pageCount: loaded.pageCount)
            : 0
        return true
    }

    private func clearLoadedSource(message: String) {
        errorMessage = message
        source = .empty
        imageLoader.reset()
        currentSourceURL = nil
        siblings = []
    }

    // MARK: - Scope helpers

    func isInsideCurrentTree(_ url: URL) -> Bool {
        if tempDir.contains(url) { return true }
        return libraryScope.contains(url)
    }

    private func isSupportedArchive(_ url: URL) -> Bool {
        !isDirectory(url) && CBZLoader.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private func libraryRootURLIfItContains(_ url: URL) -> URL? {
        guard let root = libraryRootURL,
              root.isAncestor(of: url) else {
            return nil
        }
        return root
    }

    // MARK: - Per-book position memory

    /// Position key for `url`, derived from the URL + the active temp root
    /// (so zip-in-zip volumes get a stable key that survives re-extractions).
    func positionKey(for url: URL) -> String {
        positionKeys(for: url).primary
    }

    private func positionKeys(for url: URL) -> PositionKey.Keys {
        PositionKey.keys(
            for: url,
            opened: openedSourceURL,
            tempRoot: tempDir.url
        )
    }

    /// Schedule a debounced save for the current page. Called from the
    /// `currentPageIndex` didSet, so this fires once per page change — even
    /// during 60 Hz vertical scroll the store coalesces into a single write.
    func savePosition() {
        guard let url = currentSourceURL else { return }
        let keys = positionKeys(for: url)
        positions.savePosition(
            forKey: keys.primary,
            fileIdentityKey: keys.fileIdentity,
            pageIndex: currentPageIndex
        )
    }

    /// Synchronous flush used by the app-terminate observer.
    func flushPositionImmediately() {
        guard let url = currentSourceURL else { return }
        let keys = positionKeys(for: url)
        positions.flushImmediately(
            forKey: keys.primary,
            fileIdentityKey: keys.fileIdentity,
            pageIndex: currentPageIndex
        )
    }

    func restoredIndex(for url: URL) -> Int {
        let keys = positionKeys(for: url)
        return positions.restoredIndex(
            forKey: keys.primary,
            fileIdentityKey: keys.fileIdentity
        )
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

            return volumes.sorted(by: NaturalSort.byFilename)
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

            let sorted = volumes.sorted(by: NaturalSort.byFilename)

            return (hasImages, sorted)
        }.value
    }
}
