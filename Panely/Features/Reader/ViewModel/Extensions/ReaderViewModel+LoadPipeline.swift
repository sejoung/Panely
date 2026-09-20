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
    case preferredPathMissing(String)

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let error):
            return "Failed to extract archive: \(error.localizedDescription)"
        case .preferredPathMissing:
            return "The saved book is no longer available in this source."
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
        // A selected volume can itself be a container folder (for example an
        // inner ZIP that expands to `722/722 pages/*.jpg`). Keep the outer
        // volume list before folder resolution descends into that wrapper;
        // otherwise the wrapper's single child replaces the whole series and
        // the sidebar's Volumes section appears to collapse.
        var siblingsToUse = knownSiblings
        if siblingsToUse == nil,
           siblings.contains(where: {
               $0.standardizedFileURL == url.standardizedFileURL
           }) {
            siblingsToUse = siblings
        }

        do {
            guard let archiveTarget = try await resolveArchiveTarget(for: targetURL, epoch: myEpoch) else {
                return
            }
            if archiveTarget.standardizedFileURL != url.standardizedFileURL {
                // `prepareScope` leaves `openedSourceURL` alone for a URL inside
                // the scoped library, but everything keyed off the extraction
                // (position/progress keys, series identity, favorites, reload,
                // the on-disk change monitor) needs the archive that owns it —
                // not the library folder or whichever book was open before.
                // Pin the library root first: it is derived from
                // `openedSourceURL`, and the Files tree shouldn't re-root onto
                // the archive's parent just because a nested archive opened.
                if openedSourceURL?.standardizedFileURL != url.standardizedFileURL {
                    if explicitLibraryRootURL == nil {
                        explicitLibraryRootURL = libraryRootURLIfItContains(url)
                    }
                    openedSourceURL = url
                }
                // `url` turned out to be a zip-in-zip: its volumes live in the
                // extraction, so a sibling list naming the outer archive (the
                // library folder it sits in) doesn't describe them. Carrying
                // it over would fill the Volumes section with outer files and
                // leave prev/next volume without a current index.
                siblingsToUse = nil
            }
            targetURL = try targetByApplyingPreferredRelativePath(
                to: archiveTarget,
                applyingPreferredRelativePath: intent.preferredRelativePath,
                required: intent.requiresPreferredRelativePath
            )
            // Jumping straight to a saved inner path skips the top-down
            // descent below, so the volume list has to be found by climbing
            // back toward the root the path was resolved against.
            let siblingRoot: URL?
            if let tempRoot = tempDir.url {
                siblingRoot = tempRoot
            } else if targetURL != archiveTarget {
                siblingRoot = archiveTarget
            } else {
                siblingRoot = nil
            }

            guard let folderTarget = await resolveFolderTarget(for: targetURL, epoch: myEpoch) else {
                return
            }

            switch folderTarget {
            case .book(let url, let siblings):
                targetURL = url
                // Explicit/existing sibling context describes the selected
                // volume's series and takes precedence over any child folders
                // discovered while descending to the actual image directory.
                siblingsToUse = siblingsToUse ?? siblings
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
                siblingRoot: siblingRoot,
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
            if let loadError = error as? ReaderLoadError,
               case .preferredPathMissing(let relativePath) = loadError {
                invalidateMissingPreferredPath(sourceURL: url, relativePath: relativePath)
            }
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
        unavailableRecentItem = nil
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
        // Extract into a private staging dir and only move the finished tree
        // into the keyed cache slot. The slot has no completion marker — any
        // non-empty dir there is a cache hit — so extracting in place would
        // let a quit mid-extraction poison every later open with a truncated
        // tree, and let a superseded load's cleanup delete the very dir a
        // newer load of the same archive had already adopted.
        let staging = ReaderTempDirectory.makeSessionCandidate()

        do {
            try await CBZLoader.extractAll(from: url, to: staging)
            guard epoch == loadEpoch else {
                try? FileManager.default.removeItem(at: staging)
                return nil
            }
            let candidate: URL
            if let key {
                let slot = extractionCache.makeCachedCandidate(forKey: key)
                candidate = await Self.promoteExtraction(staging, toCacheSlot: slot)
                guard epoch == loadEpoch else {
                    if candidate == staging {
                        try? FileManager.default.removeItem(at: staging)
                    }
                    return nil
                }
            } else {
                candidate = staging
            }
            tempDir.adopt(candidate)
            AppLog.info(
                .load,
                "Nested archive extracted",
                metadata: ["source": "\(DiagnosticRedactor.describe(url))"]
            )
            if extractionCache.isCacheURL(candidate) {
                Task.detached(priority: .background) {
                    // Exclude the just-extracted cache dir for the book we're
                    // about to read so the budget sweep can't evict it.
                    extractionCache.enforceBudget(excluding: candidate)
                }
            }
            return candidate
        } catch {
            try? FileManager.default.removeItem(at: staging)
            let message = DiagnosticRedactor.redactKnownPaths(in: error.localizedDescription, urls: [url, staging])
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

    /// Move a finished extraction into its cache slot and return where the
    /// tree ended up. If another load filled the slot first, its copy wins and
    /// the staging dir is discarded; if the move fails, the staging dir is
    /// used as a plain session dir (removed on book switch) instead.
    private nonisolated static func promoteExtraction(_ staging: URL, toCacheSlot slot: URL) async -> URL {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if let existing = try? fm.contentsOfDirectory(atPath: slot.path) {
                guard existing.isEmpty else {
                    try? fm.removeItem(at: staging)
                    return slot
                }
                try? fm.removeItem(at: slot)
            }
            do {
                try fm.moveItem(at: staging, to: slot)
                return slot
            } catch {
                return staging
            }
        }.value
    }

    private func targetByApplyingPreferredRelativePath(
        to targetURL: URL,
        applyingPreferredRelativePath relativePath: String?,
        required: Bool
    ) throws -> URL {
        guard let relativePath, !relativePath.isEmpty else {
            return targetURL
        }

        let root: URL
        if tempDir.isActive, let tempRoot = tempDir.url {
            root = tempRoot
        } else if isDirectory(targetURL) {
            // Continue Reading can point from a remembered container folder
            // to the actual child volume that supplied its progress.
            root = targetURL
        } else {
            if required { throw ReaderLoadError.preferredPathMissing(relativePath) }
            return targetURL
        }

        let preferred = root
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard root.isAncestor(of: preferred),
              FileManager.default.fileExists(atPath: preferred.path) else {
            if required { throw ReaderLoadError.preferredPathMissing(relativePath) }
            return targetURL
        }
        return preferred
    }

    private func invalidateMissingPreferredPath(sourceURL: URL, relativePath: String) {
        let source = sourceURL.standardizedFileURL
        let primary: String
        let fileIdentity: String?
        if isDirectory(source) {
            primary = source.appendingPathComponent(relativePath).standardizedFileURL.path
            fileIdentity = nil
        } else {
            primary = source.path + "#" + relativePath
            fileIdentity = PositionKey.fileIdentity(for: source).map { $0 + "#" + relativePath }
        }
        readingProgress.remove(forKey: primary, fileIdentityKey: fileIdentity)
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
            // sibling set as volume navigation. A wrapper level (an inner ZIP
            // expanding to `722/722 pages/*.jpg`) is not a series — it must
            // not replace the volume list found above it.
            if resolvedSiblings == nil || FolderResolver.isSeriesLevel(volumes) {
                resolvedSiblings = volumes
            }
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
        siblingRoot: URL?,
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
        } else if let siblingRoot, siblingRoot.isAncestor(of: targetURL) {
            resolvedSiblings = await FolderResolver.nearestSeriesVolumes(
                of: targetURL,
                boundedBy: siblingRoot
            )
            guard epoch == loadEpoch else { return false }
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
