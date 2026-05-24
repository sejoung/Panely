import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        Task { await load(url: url, preservingLibraryRoot: true) }
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
        preferredRelativePath: String? = nil,
        preservingLibraryRoot: Bool = false,
        restorePosition: Bool = true
    ) async {
        imageLoader.cancelPreload()

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
        let preservedLibraryRootURL = preservingLibraryRoot
            ? libraryRootURLIfItContains(url)
            : nil
        defer {
            if myEpoch == loadEpoch {
                isLoading = false
                loadingMessage = ""
            }
        }

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

        var targetURL = url
        var siblingsToUse = knownSiblings

        if !tempDir.isActive {
            let ext = url.pathExtension.lowercased()
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDir && CBZLoader.supportedExtensions.contains(ext) {
                loadingMessage = "Analyzing archive…"
                if let hasNested = try? await CBZLoader.hasNestedArchives(at: url) {
                    guard myEpoch == loadEpoch else { return }
                    if hasNested {
                        // Cache hit fast path — same archive (same path +
                        // size + mtime) reuses the previous extraction so
                        // reopen is instant. Edits to the source bump
                        // mtime → new key → automatic re-extraction.
                        let key = ReaderTempDirectory.cacheKey(for: url)
                        if let key,
                           let cached = ReaderTempDirectory.cachedEntry(forKey: key) {
                            tempDir.adopt(cached)
                            targetURL = cached
                        } else {
                            loadingMessage = "Extracting archive…"
                            // Use the cached destination when we have a
                            // key; fall back to a UUID session dir when
                            // the source can't be stat'd.
                            let candidate = key.map(ReaderTempDirectory.makeCachedCandidate(forKey:))
                                ?? ReaderTempDirectory.makeSessionCandidate()
                            do {
                                try await CBZLoader.extractAll(from: url, to: candidate)
                                guard myEpoch == loadEpoch else {
                                    // Newer load is in flight; don't keep
                                    // the candidate we just extracted —
                                    // partial state isn't safe to serve
                                    // and would otherwise leak.
                                    try? FileManager.default.removeItem(at: candidate)
                                    return
                                }
                                tempDir.adopt(candidate)
                                targetURL = candidate
                                // New cache entry might push us over budget.
                                // Sweep async on a background queue so the
                                // size walk doesn't block first-paint.
                                if key != nil {
                                    Task.detached(priority: .background) {
                                        ReaderTempDirectory.enforceCacheBudget()
                                    }
                                }
                            } catch {
                                try? FileManager.default.removeItem(at: candidate)
                                guard myEpoch == loadEpoch else { return }
                                errorMessage = "Failed to extract archive: \(error.localizedDescription)"
                                source = .empty
                                imageLoader.reset()
                                currentSourceURL = nil
                                siblings = []
                                libraryScope.release()
                                return
                            }
                        }
                    }
                }
            }
        }

        if let preferredRelativePath,
           !preferredRelativePath.isEmpty,
           tempDir.isActive,
           let root = tempDir.url {
            let preferred = root
                .appendingPathComponent(preferredRelativePath)
                .standardizedFileURL
            if root.isAncestor(of: preferred),
               FileManager.default.fileExists(atPath: preferred.path) {
                targetURL = preferred
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
                imageLoader.reset()
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
            currentPageIndex = restorePosition
                ? clampedRestoredIndex(for: targetURL, pageCount: loaded.pageCount)
                : 0
            errorMessage = loaded.isEmpty ? "No images found" : nil
            await refreshImages()
        } catch {
            guard myEpoch == loadEpoch else { return }
            errorMessage = error.localizedDescription
            source = .empty
            imageLoader.reset()
            currentSourceURL = nil
            siblings = []
            libraryScope.release()
        }
    }

    // MARK: - Scope helpers

    func isInsideCurrentTree(_ url: URL) -> Bool {
        if tempDir.contains(url) { return true }
        return libraryScope.contains(url)
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
        PositionKey.make(
            for: url,
            opened: openedSourceURL,
            tempRoot: tempDir.url
        )
    }

    /// Mirror key used as a fallback when the path-keyed entry misses (e.g.,
    /// after a mount-path drift). `nil` when `PositionKey.fileIdentity` can't
    /// derive an identity. Temp-backed volumes use the originally opened
    /// archive plus an inner path because their extracted file identities are
    /// not stable; normal folder/zip lists use each volume's own identity so
    /// siblings don't share one fallback slot.
    private func fileIdentityKey(for url: URL) -> String? {
        if let tempKey = tempBackedFileIdentityKey(for: url) {
            return tempKey
        }
        return PositionKey.fileIdentity(for: url)
    }

    private func tempBackedFileIdentityKey(for url: URL) -> String? {
        guard let openedSourceURL,
              let identity = PositionKey.fileIdentity(for: openedSourceURL),
              let tempRoot = tempDir.url else {
            return nil
        }

        let rootPath = tempRoot.standardizedFileURL.path
        let sourcePath = url.standardizedFileURL.path
        if sourcePath == rootPath {
            return identity
        }

        guard sourcePath != rootPath,
              sourcePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        let innerPath = String(sourcePath.dropFirst(rootPath.count + 1))
        return identity + "#" + innerPath
    }

    /// Schedule a debounced save for the current page. Called from the
    /// `currentPageIndex` didSet, so this fires once per page change — even
    /// during 60 Hz vertical scroll the store coalesces into a single write.
    func savePosition() {
        guard let url = currentSourceURL else { return }
        positions.savePosition(
            forKey: positionKey(for: url),
            fileIdentityKey: fileIdentityKey(for: url),
            pageIndex: currentPageIndex
        )
    }

    /// Synchronous flush used by the app-terminate observer.
    func flushPositionImmediately() {
        guard let url = currentSourceURL else { return }
        positions.flushImmediately(
            forKey: positionKey(for: url),
            fileIdentityKey: fileIdentityKey(for: url),
            pageIndex: currentPageIndex
        )
    }

    func restoredIndex(for url: URL) -> Int {
        positions.restoredIndex(
            forKey: positionKey(for: url),
            fileIdentityKey: fileIdentityKey(for: url)
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
