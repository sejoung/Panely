import Foundation
import ZIPFoundation

nonisolated enum CBZLoader {
    static let supportedExtensions: Set<String> = ["cbz", "zip"]

    static func load(from url: URL) async throws -> ComicSource {
        try await Task.detached(priority: .userInitiated) {
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
        }.value
    }

    static func hasNestedArchives(at url: URL) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            let reader = try ArchiveReader(url: url)
            let paths = await reader.entryPaths()
            return paths.contains { path in
                let ext = (path as NSString).pathExtension.lowercased()
                return supportedExtensions.contains(ext)
            }
        }.value
    }

    static func extractAll(from url: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
            try FileManager.default.unzipItem(at: url, to: destination)
            try extractNestedArchives(in: destination, depth: 0)
        }.value
    }

    private static let maxNestingDepth = 3

    private static func extractNestedArchives(in directory: URL, depth: Int) throws {
        guard depth < maxNestingDepth else { return }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for entry in contents {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDir {
                try extractNestedArchives(in: entry, depth: depth + 1)
                continue
            }

            let ext = entry.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            let destDir = entry.deletingPathExtension()
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: entry, to: destDir)
            try FileManager.default.removeItem(at: entry)
            try extractNestedArchives(in: destDir, depth: depth + 1)
        }
    }
}
