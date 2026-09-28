import Foundation
import UnrarKit

/// RAR (RAR 1.5–4.x and RAR 5) reader backed by UnrarKit.
///
/// Non-solid archives are read per entry, like ZIP. Solid archives compress
/// all entries as one continuous stream, so reading entry N means
/// decompressing entries 0..<N first — paging, thumbnails and the dimension
/// pre-pass would turn that into O(n²) work. For those the whole archive is
/// extracted once, on first access, into a private temp directory that lives
/// as long as the reader; entries are then served from disk.
actor RARArchiveReader: ArchiveReader {
    nonisolated let archiveURL: URL
    private let archive: URKArchive
    nonisolated let isSolid: Bool
    private var solidExtractionRoot: URL?
    private var knownPaths: Set<String>?

    init(url: URL) throws {
        self.archiveURL = url
        self.archive = try Self.openArchive(at: url)
        let archive = self.archive
        self.isSolid = Self.unrarLock.withLock { archive.isSolid() }
    }

    deinit {
        if let solidExtractionRoot {
            try? FileManager.default.removeItem(at: solidExtractionRoot)
        }
    }

    func entryPaths() throws -> [String] {
        let infos = try Self.withUnrar { try archive.listFileInfo() }
        // Same dedupe as `ZIPArchiveReader`: entries are addressed by path,
        // so a repeated path would alias the first entry's bytes.
        var seen = Set<String>()
        var paths: [String] = []
        for info in infos where !info.isDirectory {
            if seen.insert(info.filename).inserted {
                paths.append(info.filename)
            }
        }
        knownPaths = seen
        return paths
    }

    func loadData(at path: String) throws -> Data {
        try requireEntry(path)
        if isSolid {
            return try Data(contentsOf: try extractedFileURL(for: path))
        }
        return try Self.withUnrar { try archive.extractData(fromFile: path) }
    }

    /// Non-solid: cancels UnrarKit's buffered extraction through its
    /// `NSProgress` once enough bytes have arrived. Solid: reads the head of
    /// the already-extracted file.
    func loadDataPrefix(at path: String, maxBytes: Int) throws -> Data {
        try requireEntry(path)
        if isSolid {
            let handle = try FileHandle(forReadingFrom: try extractedFileURL(for: path))
            defer { try? handle.close() }
            return try handle.read(upToCount: maxBytes) ?? Data()
        }

        let progress = Progress(totalUnitCount: 0)
        archive.progress = progress
        var buffer = Data()
        do {
            try Self.withUnrar {
                try archive.extractBufferedData(fromFile: path) { chunk, _ in
                    buffer.append(chunk)
                    if buffer.count >= maxBytes {
                        progress.cancel()
                    }
                }
            }
        } catch {
            // Cancellation is how we stop early — only a real failure before
            // the prefix filled up is worth surfacing.
            guard progress.isCancelled, buffer.count >= maxBytes else { throw error }
        }
        return buffer
    }

    /// UnrarKit finds an entry by scanning headers to the end of the archive,
    /// and its buffered path doesn't reliably report a miss — check up front.
    private func requireEntry(_ path: String) throws {
        let paths = try knownPaths ?? Set(entryPaths())
        guard paths.contains(path) else {
            throw ArchiveReaderError.entryNotFound(path)
        }
    }

    // MARK: - Solid archives

    private func extractedFileURL(for path: String) throws -> URL {
        let root = try extractSolidArchiveIfNeeded()
        let fileURL = root.appendingPathComponent(path).standardizedFileURL
        guard root.isAncestor(of: fileURL),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ArchiveReaderError.entryNotFound(path)
        }
        return fileURL
    }

    private func extractSolidArchiveIfNeeded() throws -> URL {
        if let solidExtractionRoot { return solidExtractionRoot }

        let limit = ArchiveLoader.maxExtractedBytes
        if let declared = archive.uncompressedSize?.uint64Value, declared > limit {
            throw ArchiveLoader.LoadError.extractedSizeExceeded(limit: limit)
        }

        // `panely-` prefix: a crash mid-read leaves this behind, and the
        // startup sweep in `ReaderTempDirectory` collects it.
        let root = ReaderTempDirectory.makeSessionCandidate().standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.withUnrar { try archive.extractFiles(to: root.path, overwrite: false) }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        solidExtractionRoot = root
        return root
    }

    // MARK: - Whole-archive operations

    /// Extracts every entry under `destination`. unrar sanitises entry paths
    /// (absolute paths and `..` components) so nothing lands outside it.
    static func extractAll(from url: URL, to destination: URL) throws {
        let archive = try openArchive(at: url)
        try withUnrar { try archive.extractFiles(to: destination.path, overwrite: false) }
    }

    /// Sum of the uncompressed sizes recorded in the entry headers.
    static func declaredUncompressedSize(of url: URL) throws -> UInt64 {
        let archive = try openArchive(at: url)
        let infos = try withUnrar { try archive.listFileInfo() }
        return infos.reduce(UInt64(0)) { total, info in
            guard !info.isDirectory else { return total }
            let (sum, overflow) = total.addingReportingOverflow(UInt64(max(info.uncompressedSize, 0)))
            return overflow ? .max : sum
        }
    }

    private static func openArchive(at url: URL) throws -> URKArchive {
        guard URKArchive.urlIsARAR(url), let archive = try? URKArchive(url: url) else {
            throw ArchiveReaderError.cannotOpen(url)
        }
        return archive
    }

    // MARK: - unrar access

    /// unrar keeps its error state in one process-wide object (`ErrHandler`),
    /// so concurrent operations — even on different archives — report each
    /// other's failures (typically as `ERAR_UNKNOWN`). Every UnrarKit call
    /// that reaches unrar goes through this lock.
    private static let unrarLock = NSLock()

    /// Runs `body` under `unrarLock` and maps UnrarKit's password errors.
    private static func withUnrar<T>(_ body: () throws -> T) throws -> T {
        unrarLock.lock()
        defer { unrarLock.unlock() }
        do {
            return try body()
        } catch let error as NSError where error.domain == URKErrorDomain {
            switch URKErrorCode(rawValue: error.code) {
            case .missingPassword?, .badPassword?:
                throw ArchiveReaderError.passwordProtected
            default:
                throw error
            }
        }
    }
}
