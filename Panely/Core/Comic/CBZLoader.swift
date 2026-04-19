import Foundation

nonisolated enum CBZLoader {
    static let supportedExtensions: Set<String> = ["cbz", "zip"]

    static func load(from url: URL) async throws -> ComicSource {
        let reader = try ArchiveReader(url: url)
        let paths = await reader.entryPaths()

        let imagePaths = paths.filter { path in
            let ext = (path as NSString).pathExtension.lowercased()
            return FolderLoader.supportedExtensions.contains(ext)
        }

        let sorted = imagePaths.sorted { a, b in
            a.localizedStandardCompare(b) == .orderedAscending
        }

        let pages = sorted.map { path in
            ComicPage(
                source: .archiveEntry(reader: reader, path: path),
                displayName: (path as NSString).lastPathComponent
            )
        }

        let title = url.deletingPathExtension().lastPathComponent
        return ComicSource(title: title, pages: pages)
    }
}
