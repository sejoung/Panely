import Foundation

/// Off-main folder scanners shared by the load pipeline and the explicit
/// library-root flow. Pure file-system inspection: each call is a single
/// `contentsOfDirectory` walk plus naturally-sorted filtering. The decision
/// of how to drive these (descend, restart load, etc.) lives in
/// `ReaderViewModel` — the resolver itself has no opinions about state.
nonisolated enum FolderResolver {
    /// Volume listing for a directory: child folders plus archive files,
    /// naturally sorted. Used to seed the volume nav and the sibling list.
    static func enumerateVolumes(in directory: URL) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            volumes(in: directory)
        }.value
    }

    /// Directory names that never hold a book. Finder's "Compress" adds a
    /// `__MACOSX` resource-fork folder next to the real content; counting it
    /// as a volume makes a wrapper level look like a two-volume series.
    private static let ignoredDirectoryNames: Set<String> = ["__MACOSX"]

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private static func isVolume(_ candidate: URL) -> Bool {
        if isDirectory(candidate) {
            return !ignoredDirectoryNames.contains(candidate.lastPathComponent)
        }
        return CBZLoader.supportedExtensions.contains(candidate.pathExtension.lowercased())
    }

    private static func volumes(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        return contents.filter(isVolume).sorted(by: NaturalSort.byFilename)
    }

    /// Whether a folder's volume listing describes a series the reader should
    /// navigate, as opposed to a wrapper level. A lone child *folder* is a
    /// wrapper (an inner ZIP expanding to `722/722 pages/*.jpg`); a lone
    /// archive is a genuine one-volume series. Shared by the load pipeline's
    /// top-down descent and `nearestSeriesVolumes` so opening and reopening
    /// the same book agree on its volume list.
    static func isSeriesLevel(_ volumes: [URL]) -> Bool {
        if volumes.count > 1 { return true }
        guard let only = volumes.first else { return false }
        return !isDirectory(only)
    }

    /// Volume list for a book opened directly at a saved path below `root`
    /// (Continue Reading, Reload, Favorites skip the top-down descent). Climbs
    /// from `target` toward `root` and returns the nearest series level; when
    /// every level is a wrapper, falls back to the outermost listing — the
    /// same list the descent from `root` would have produced.
    static func nearestSeriesVolumes(of target: URL, boundedBy root: URL) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            let rootPath = root.standardizedFileURL.path
            var candidate = target
            var outermost: [URL] = []
            while candidate.standardizedFileURL.path != rootPath,
                  root.isAncestor(of: candidate) {
                let parent = candidate.deletingLastPathComponent()
                let listing = volumes(in: parent)
                if isSeriesLevel(listing) { return listing }
                if !listing.isEmpty { outermost = listing }
                candidate = parent
            }
            return outermost.isEmpty ? [target] : outermost
        }.value
    }

    /// Sibling list for `url`. Returns the parent's enumerated volumes if
    /// any exist; falls back to `[url]` so the caller always has at least
    /// one entry (the book itself) for nav UI.
    static func scanSiblings(of url: URL) async -> [URL] {
        let volumes = await enumerateVolumes(in: url.deletingLastPathComponent())
        return volumes.isEmpty ? [url] : volumes
    }

    /// One-pass inspection of a folder. Reports whether it contains any
    /// directly-readable image pages (i.e. *is* the book), and lists the
    /// sub-volumes (folders + archives) it contains. Image files surface
    /// `hasImages = true` but are not listed in `volumes`; the load pipeline
    /// hands the folder itself to `FolderLoader` in that case.
    static func analyzeFolder(_ url: URL) async -> (hasImages: Bool, volumes: [URL]) {
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
                if isVolume(entry) {
                    volumes.append(entry)
                } else if !isDirectory(entry),
                          FolderLoader.supportedExtensions.contains(entry.pathExtension.lowercased()) {
                    hasImages = true
                }
            }

            let sorted = volumes.sorted(by: NaturalSort.byFilename)

            return (hasImages, sorted)
        }.value
    }
}
