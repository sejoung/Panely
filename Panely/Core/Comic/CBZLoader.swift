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

    static func extractAll(
        from url: URL,
        to destination: URL,
        maxExtractedBytes limit: UInt64 = Self.maxExtractedBytes
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            do {
                try checkDeclaredArchiveSize(
                    of: url,
                    currentTotal: 0,
                    replacingArchiveBytes: 0,
                    limit: limit,
                    cleanup: destination
                )
                try fm.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
                try fm.unzipItem(at: url, to: destination)
                // Running cumulative byte count, threaded through the nested
                // descent so each step only sums the bytes it just added
                // instead of re-walking the whole growing tree (O(n) overall
                // rather than O(n²) on archives with many nested archives).
                var totalBytes = directorySize(at: destination)
                try checkLimit(totalBytes, limit: limit, cleanup: destination)
                try extractNestedArchives(
                    in: destination,
                    root: destination,
                    depth: 0,
                    maxExtractedBytes: limit,
                    totalBytes: &totalBytes
                )
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
        }.value
    }

    private static let maxNestingDepth = 3

    private static func extractNestedArchives(
        in directory: URL,
        root: URL,
        depth: Int,
        maxExtractedBytes limit: UInt64,
        totalBytes: inout UInt64
    ) throws {
        guard depth < maxNestingDepth else { return }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for entry in contents {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDir {
                try extractNestedArchives(
                    in: entry,
                    root: root,
                    depth: depth + 1,
                    maxExtractedBytes: limit,
                    totalBytes: &totalBytes
                )
                continue
            }

            let ext = entry.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            let destDir = entry.deletingPathExtension()
            let archiveBytes = fileSize(at: entry)
            try checkDeclaredArchiveSize(
                of: entry,
                currentTotal: totalBytes,
                replacingArchiveBytes: archiveBytes,
                limit: limit,
                cleanup: root
            )
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: entry, to: destDir)
            try FileManager.default.removeItem(at: entry)
            // Net change to the running total: drop the now-removed archive
            // file, add the bytes it expanded into. Only the new folder is
            // walked — never the whole root.
            totalBytes = totalBytes >= archiveBytes ? totalBytes - archiveBytes : 0
            totalBytes &+= directorySize(at: destDir)
            try checkLimit(totalBytes, limit: limit, cleanup: root)
            try extractNestedArchives(
                in: destDir,
                root: root,
                depth: depth + 1,
                maxExtractedBytes: limit,
                totalBytes: &totalBytes
            )
        }
    }

    /// Abort (and clean up) if the cumulative extracted byte count has crossed
    /// `maxExtractedBytes`.
    private static func checkLimit(_ total: UInt64, limit: UInt64, cleanup: URL) throws {
        guard total > limit else { return }
        // Clean up partial extraction so the caller's temp dir doesn't leak.
        // extractAll/load already removes on error too.
        try? FileManager.default.removeItem(at: cleanup)
        throw LoadError.extractedSizeExceeded(limit: limit)
    }

    private static func checkDeclaredArchiveSize(
        of archiveURL: URL,
        currentTotal: UInt64,
        replacingArchiveBytes: UInt64,
        limit: UInt64,
        cleanup: URL
    ) throws {
        let base = currentTotal >= replacingArchiveBytes ? currentTotal - replacingArchiveBytes : 0
        let declared = try declaredUncompressedSize(of: archiveURL)
        try checkLimit(saturatedAdd(base, declared), limit: limit, cleanup: cleanup)
    }

    private static func declaredUncompressedSize(of archiveURL: URL) throws -> UInt64 {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        return archive.reduce(UInt64(0)) { total, entry in
            guard entry.type != .directory else { return total }
            return saturatedAdd(total, entry.uncompressedSize)
        }
    }

    /// Sum the on-disk size of every file under `directory`. Overflow-safe
    /// (`&+`); missing/unreadable sizes count as 0.
    private static func directorySize(at directory: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let url as URL in enumerator {
            total &+= fileSize(at: url)
        }
        return total
    }

    private static func fileSize(at url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
        ])
        return UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    private static func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
