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
