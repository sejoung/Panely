import AppKit
import Foundation

/// The actual `load(url:)` state machine. The split with `+Source` keeps
/// the entry points (Open…, openURL, library root, reload, position memory)
/// readable on their own while the multi-stage pipeline below — epoch
/// guarding, archive extraction, folder descent, sibling resolution, apply
/// — has room to breathe.
///
/// Every async step re-checks `loadEpoch` after returning so a stale load
/// can't overwrite state set by a newer one. Failure paths funnel through
/// `clearLoadedSource` so partial state is never left behind.

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

extension ReaderViewModel {

    func load(
        url: URL,
        knownSiblings: [URL]? = nil,
        intent: ReaderLoadIntent = .open
    ) async {
        AppLog.info(
            .load,
            "Load started",
            metadata: [
                "intent": "\(intent.diagnosticName)",
                "source": "\(DiagnosticRedactor.describe(url))",
            ]
        )
        let myEpoch = startLoad()
        pendingSourceURL = url
        let preservesExistingLibraryContext = libraryRootURLIfItContains(url) != nil
        let preservedLibraryRootURL = intent.preservesLibraryRoot
            ? libraryRootURLIfItContains(url)
            : nil
        defer {
            if myEpoch == loadEpoch {
                isLoading = false
                loadingMessage = ""
            }
        }

        let didAcquireScopeForLoad = prepareScope(
            for: url,
            preservedLibraryRootURL: preservedLibraryRootURL
        )

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
                if let siblings {
                    AppLog.info(
                        .load,
                        "Folder resolved to book",
                        metadata: [
                            "siblings": "\(siblings.count)",
                            "source": "\(DiagnosticRedactor.describe(url))",
                        ]
                    )
                }
            case .empty:
                AppLog.info(
                    .load,
                    "Folder resolved empty",
                    metadata: ["source": "\(DiagnosticRedactor.describe(targetURL))"]
                )
                clearLoadedSource(
                    message: "Folder is empty or has no supported content",
                    preserveLibraryContext: preservesExistingLibraryContext
                )
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
            // Library root has settled — point the directory watcher at it so
            // files added on disk refresh the sidebar tree automatically.
            syncLibraryWatcher()
            errorMessage = loaded.isEmpty ? "No images found" : nil
            AppLog.info(
                .load,
                "Load finished",
                metadata: [
                    "pages": "\(loaded.pageCount)",
                    "siblings": "\(siblings.count)",
                    "source": "\(DiagnosticRedactor.describe(targetURL))",
                ]
            )
            await refreshImages()
        } catch {
            guard myEpoch == loadEpoch else { return }
            let message = DiagnosticRedactor.redactKnownPaths(
                in: error.localizedDescription,
                urls: [url, targetURL]
            )
            AppLog.error(
                .load,
                "Load failed",
                metadata: [
                    "error": "\(message)",
                    "source": "\(DiagnosticRedactor.describe(url))",
                ]
            )
            clearLoadedSource(
                message: error.localizedDescription,
                preserveLibraryContext: preservesExistingLibraryContext
            )
            if didAcquireScopeForLoad {
                libraryScope.release()
            }
        }
    }

    private func startLoad() -> Int {
        imageLoader.cancelBackgroundWork()
        ThumbnailLoader.shared.removeAll()
        sourceRenderRevision &+= 1
        clearSourceChangeNotice()
        sourceChangeMonitor?.stopWatching()

        // Any new book load — explicit, via prev/next volume, or via library
        // — resets the prev-volume cue. Without this, opening Vol N+1 after
        // dismissing Vol N's card by jumping pages could carry the stale flag
        // when the new book's saved position lands at index 0 (didSet on
        // currentPageIndex doesn't fire when oldValue == newValue == 0).
        wantsPreviousVolumePrompt = false

        loadEpoch &+= 1
        isLoading = true
        loadingMessage = "Opening…"
        // Drop the outgoing book's strip now (while isLoading guards against a
        // scroll-driven position overwrite) so the new book's restored-position
        // scroll-sync doesn't run against the previous book's stale frames.
        imageLoader.prepareForBookSwitch()
        return loadEpoch
    }

    @discardableResult
    private func prepareScope(for url: URL, preservedLibraryRootURL: URL?) -> Bool {
        if !isInsideCurrentTree(url) {
            tempDir.cleanup()
            let didAcquire = libraryScope.acquire(url)
            explicitLibraryRootURL = preservedLibraryRootURL
            openedSourceURL = url
            return didAcquire
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
        return false
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
        AppLog.info(
            .load,
            "Nested archive detected",
            metadata: ["source": "\(DiagnosticRedactor.describe(url))"]
        )

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
            AppLog.info(
                .cache,
                "Extraction cache hit",
                metadata: [
                    "key": "\(key)",
                    "source": "\(DiagnosticRedactor.describe(url))",
                ]
            )
            tempDir.adopt(cached)
            return cached
        }

        loadingMessage = "Extracting archive…"
        if let key {
            AppLog.info(
                .cache,
                "Extraction cache miss",
                metadata: [
                    "key": "\(key)",
                    "source": "\(DiagnosticRedactor.describe(url))",
                ]
            )
        } else {
            AppLog.info(
                .cache,
                "Extraction cache unavailable",
                metadata: ["source": "\(DiagnosticRedactor.describe(url))"]
            )
        }
        let candidate = key.map { extractionCache.makeCachedCandidate(forKey: $0) }
            ?? ReaderTempDirectory.makeSessionCandidate()

        do {
            try await CBZLoader.extractAll(from: url, to: candidate)
            guard epoch == loadEpoch else {
                try? FileManager.default.removeItem(at: candidate)
                return nil
            }
            tempDir.adopt(candidate)
            AppLog.info(
                .load,
                "Nested archive extracted",
                metadata: ["source": "\(DiagnosticRedactor.describe(url))"]
            )
            if key != nil {
                Task.detached(priority: .background) {
                    // Exclude the just-extracted cache dir for the book we're
                    // about to read so the budget sweep can't evict it.
                    extractionCache.enforceBudget(excluding: candidate)
                }
            }
            return candidate
        } catch {
            try? FileManager.default.removeItem(at: candidate)
            let message = DiagnosticRedactor.redactKnownPaths(in: error.localizedDescription, urls: [url, candidate])
            AppLog.error(
                .load,
                "Nested archive extraction failed",
                metadata: [
                    "error": "\(message)",
                    "source": "\(DiagnosticRedactor.describe(url))",
                ]
            )
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
        var candidate = url
        var resolvedSiblings: [URL]?

        while isDirectory(candidate) {
            loadingMessage = "Scanning folder…"
            let (hasImages, volumes) = await FolderResolver.analyzeFolder(candidate)
            guard epoch == loadEpoch else { return nil }

            if hasImages {
                return .book(candidate, siblings: resolvedSiblings)
            }

            guard let first = volumes.first else {
                return .empty
            }

            // Folder series can be nested one or more levels deep:
            // Library/Series/Vol01.zip or Library/Series/Vol01/*.jpg.
            // Keep descending through "container" folders until we hit
            // an actual image folder or archive, and use the nearest
            // sibling set as volume navigation.
            resolvedSiblings = volumes
            candidate = first
        }

        return .book(candidate, siblings: resolvedSiblings)
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
            resolvedSiblings = await FolderResolver.scanSiblings(of: targetURL)
            guard epoch == loadEpoch else { return false }
        }

        source = loaded
        currentSourceURL = targetURL
        pendingSourceURL = nil
        if let resolvedSiblings {
            siblings = resolvedSiblings
        }
        // Restore this series' remembered direction/layout/fitMode before the
        // page index is computed, so the spread snap uses the final layout.
        applySeriesPreferences()
        currentPageIndex = restorePosition
            ? clampedRestoredIndex(for: targetURL, pageCount: loaded.pageCount)
            : 0
        startSourceChangeMonitor(for: targetURL, source: loaded)
        return true
    }

    func clearLoadedSource(message: String, preserveLibraryContext: Bool = false) {
        let redactedMessage = DiagnosticRedactor.redactKnownPaths(
            in: message,
            urls: [currentSourceURL, openedSourceURL, libraryRootURL, tempDir.url]
        )
        AppLog.error(.reader, "Reader source cleared", metadata: ["message": "\(redactedMessage)"])
        errorMessage = message
        source = .empty
        imageLoader.reset()
        currentSourceURL = nil
        pendingSourceURL = nil
        siblings = []
        sourceChangeMonitor?.stopWatching()
        sourceChangeMonitor = nil
        if !preserveLibraryContext {
            stopLibraryWatcher()
        }
        clearSourceChangeNotice()
    }

    private func startSourceChangeMonitor(for targetURL: URL, source: ComicSource) {
        let monitorURLs = sourceMonitorURLs(for: targetURL, source: source)
        guard !monitorURLs.isEmpty else { return }
        let monitor = sourceChangeMonitor ?? makeSourceChangeMonitor()
        sourceChangeMonitor = monitor
        monitor.startWatching(urls: monitorURLs) { [weak self] in
            self?.markSourceChangedOnDisk()
        }
    }

    private func sourceMonitorURLs(for targetURL: URL, source: ComicSource) -> [URL] {
        if tempDir.isActive {
            return existingURLs([openedSourceURL ?? targetURL])
        }

        guard isDirectory(targetURL) else {
            return existingURLs([targetURL])
        }

        let pageFiles = source.pages.compactMap { page -> URL? in
            guard case .file(let url) = page.source else { return nil }
            return url
        }

        // Watching each page file creates one file descriptor and one
        // DispatchSource per page. Keep exact per-file change detection for
        // ordinary folders, but cap large sources so a webtoon folder doesn't
        // allocate hundreds or thousands of watchers.
        guard pageFiles.count <= Self.maxPageFileWatchCount else {
            return existingURLs([targetURL])
        }
        return existingURLs([targetURL] + pageFiles)
    }

    private func existingURLs(_ urls: [URL]) -> [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func reloadRequest() -> (url: URL, innerPath: String?, knownSiblings: [URL]?)? {
        guard let currentSourceURL else { return nil }
        if tempDir.isActive,
           let root = tempDir.url,
           let openedSourceURL,
           let relativePath = root.relativeSubpath(to: currentSourceURL) {
            return (openedSourceURL, relativePath, nil)
        }
        return (currentSourceURL, nil, siblings.isEmpty ? nil : siblings)
    }

    private func isSupportedArchive(_ url: URL) -> Bool {
        !isDirectory(url) && CBZLoader.supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
