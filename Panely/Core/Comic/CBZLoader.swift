import Foundation
import ZIPFoundation

nonisolated enum CBZLoader {
    static let supportedExtensions: Set<String> = ["cbz", "zip"]

    /// Soft cap on cumulative bytes extracted by `extractAll`. Single
    /// archives can legitimately be several GB (high-res scan series), so
    /// we don't set this aggressively — the purpose is to abort obviously
    /// pathological inputs (zip-bombs, infinitely-nested archives that
    /// slipped past `maxNestingDepth`) before they fill the user's disk.
    static let maxExtractedBytes: UInt64 = 5 * 1024 * 1024 * 1024  // 5 GB

    enum LoadError: LocalizedError {
        case extractedSizeExceeded(limit: UInt64)

        var errorDescription: String? {
            switch self {
            case .extractedSizeExceeded(let limit):
                let mb = limit / (1024 * 1024)
                return "Archive expanded past the safety limit (\(mb) MB)."
            }
        }
    }

    static func load(from url: URL) async throws -> ComicSource {
        try await Task.detached(priority: .userInitiated) {
            let reader = try ArchiveReader(url: url)
            let paths = await reader.entryPaths()

            let imagePaths = paths.filter { path in
                let ext = (path as NSString).pathExtension.lowercased()
                return FolderLoader.supportedExtensions.contains(ext)
            }

            let sorted = imagePaths.sorted(by: NaturalSort.compare)

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
            try ensureSizeUnderLimit(at: destination)
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
            try ensureSizeUnderLimit(at: destDir)
            try FileManager.default.removeItem(at: entry)
            try extractNestedArchives(in: destDir, depth: depth + 1)
        }
    }

    /// Walk the just-extracted tree once and abort if the cumulative file
    /// size crosses `maxExtractedBytes`. ZIPFoundation has no streaming
    /// callback for this in `unzipItem`, so we check post-hoc — fine for
    /// the safety-net role (catches the pathological case; legitimate
    /// large archives are still allowed up to the cap).
    private static func ensureSizeUnderLimit(at directory: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileSizeKey,
            ])
            let size = UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            total &+= size
            if total > maxExtractedBytes {
                // Clean up partial extraction so the caller's temp dir
                // doesn't leak. extractAll/load already removes on error.
                try? fm.removeItem(at: directory)
                throw LoadError.extractedSizeExceeded(limit: maxExtractedBytes)
            }
        }
    }
}
