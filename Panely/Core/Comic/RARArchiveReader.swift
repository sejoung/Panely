import Foundation
import UnrarKit

/// RAR (RAR 1.5–4.x and RAR 5) reader backed by UnrarKit.
///
/// Non-solid archives are read per entry, like ZIP. Solid archives compress
/// all entries as one continuous stream, so reading entry N means
/// decompressing entries 0..<N first — paging, thumbnails and the dimension
/// pre-pass would turn that into O(n²) work. For those the whole archive is
/// extracted once, on first access, into the extraction cache (or a private
/// temp directory if it can't be keyed); entries are then served from disk,
/// and reopening the unchanged archive skips the extraction.
actor RARArchiveReader: ArchiveReader {
    nonisolated let archiveURL: URL
    private let archive: URKArchive
    nonisolated let isSolid: Bool
    private var solidExtractionRoot: URL?
    private var knownPaths: Set<String>?
    private var orderedPaths: [String] = []
    /// Prefixes read ahead of being asked for (see `readPrefixesAhead`),
    /// removed as they are handed out.
    private var prefixReadAhead: [String: Data] = [:]
    private var prefixReadAheadMaxBytes = 0
    /// How many prefixes read-ahead didn't cover. Lets tests tell a working
    /// read-ahead from a silently failing one, whose results look the same.
    private(set) var singlePrefixReadCount = 0
    /// Entries per pass. A pass walks the headers from the start, so more
    /// entries means fewer walks; each one held costs up to the prefix size
    /// (64 KB from `ImageLoader.dimensions`), so this also bounds the memory.
    private let prefixReadAheadCount: Int
    private let extractionCache: any ExtractionCacheManaging

    init(
        url: URL,
        extractionCache: any ExtractionCacheManaging = LiveExtractionCacheManager(),
        prefixReadAheadCount: Int = 128
    ) throws {
        self.archiveURL = url
        self.extractionCache = extractionCache
        self.prefixReadAheadCount = prefixReadAheadCount
        self.archive = try Self.openArchive(at: url)
        let archive = self.archive
        self.isSolid = Self.unrarLock.withLock { archive.isSolid() }
    }

    deinit {
        if let solidExtractionRoot, !extractionCache.isCacheURL(solidExtractionRoot) {
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
        orderedPaths = paths
        return paths
    }

    func loadData(at path: String) throws -> Data {
        // Checked before taking `unrarLock`: a superseded page read must not
        // queue behind (and then hold up) the reads that replaced it.
        try Task.checkCancellation()
        try requireEntry(path)
        if isSolid {
            return try Data(contentsOf: try extractedFileURL(for: path))
        }
        return try Self.withUnrar { try archive.extractData(fromFile: path) }
    }

    /// Non-solid: served from a read-ahead pass when one can be made, otherwise
    /// cancels UnrarKit's buffered extraction through its `NSProgress` once
    /// enough bytes have arrived. Solid: reads the head of the already-extracted
    /// file.
    func loadDataPrefix(at path: String, maxBytes: Int) throws -> Data {
        try Task.checkCancellation()
        try requireEntry(path)
        if isSolid {
            let handle = try FileHandle(forReadingFrom: try extractedFileURL(for: path))
            defer { try? handle.close() }
            return try handle.read(upToCount: maxBytes) ?? Data()
        }

        if maxBytes != prefixReadAheadMaxBytes {
            prefixReadAhead.removeAll()
            prefixReadAheadMaxBytes = maxBytes
        }
        if prefixReadAhead[path] == nil {
            readPrefixesAhead(startingAt: path, maxBytes: maxBytes)
        }
        if let prefix = prefixReadAhead.removeValue(forKey: path) {
            return prefix
        }
        singlePrefixReadCount += 1

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

    /// The vertical layout's dimension pre-pass asks for the head of every page,
    /// and finding one entry walks the headers from the start — O(n²) overall,
    /// about 4 s at 1000 pages on a local SSD and far worse over a network.
    /// So read the entries that follow in the archive in the same walk. Failures
    /// are ignored: whatever is missing is read on its own, which reports them.
    private func readPrefixesAhead(startingAt path: String, maxBytes: Int) {
        guard let start = orderedPaths.firstIndex(of: path) else { return }
        let wanted = orderedPaths[start...]
            .lazy
            .filter { self.prefixReadAhead[$0] == nil }
            .prefix(prefixReadAheadCount)
        var results: [String: Data] = [:]
        try? Self.withUnrar {
            try archive.extractPrefixes(ofFiles: Set(wanted), maxBytes: UInt(maxBytes)) { filePath, prefix in
                results[filePath] = prefix
            }
        }
        prefixReadAhead.merge(results) { _, new in new }
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
        // A cache entry can go while we hold it (budget sweep, Clear Cache).
        // Files already open stay readable; for the rest, extract again.
        if let solidExtractionRoot, FileManager.default.fileExists(atPath: solidExtractionRoot.path) {
            return solidExtractionRoot
        }
        solidExtractionRoot = nil

        let cacheKey = extractionCache.cacheKey(for: archiveURL)
        if let cacheKey, let cached = extractionCache.cachedEntry(forKey: cacheKey) {
            let root = cached.standardizedFileURL
            solidExtractionRoot = root
            return root
        }

        let limit = ArchiveLoader.maxExtractedBytes
        if let declared = archive.uncompressedSize?.uint64Value, declared > limit {
            throw ArchiveLoader.LoadError.extractedSizeExceeded(limit: limit)
        }

        // `panely-` prefix: a crash mid-read leaves this behind, and the
        // startup sweep in `ReaderTempDirectory` collects it.
        let staging = ReaderTempDirectory.makeSessionCandidate().standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try Self.withUnrar { try archive.extractFiles(to: staging.path, overwrite: false) }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        var root = staging
        if let cacheKey {
            let slot = extractionCache.makeCachedCandidate(forKey: cacheKey)
            root = ExtractionCacheStore.promote(staging, toCacheSlot: slot).standardizedFileURL
            if extractionCache.isCacheURL(root) {
                let cache = extractionCache
                let active = root
                Task.detached(priority: .background) {
                    cache.enforceBudget(excluding: active)
                }
            }
        }
        solidExtractionRoot = root
        return root
    }

    // MARK: - Whole-archive operations

    /// Extracts every entry under `destination`. unrar sanitises entry paths
    /// (absolute paths and `..` components) so nothing lands outside it.
    /// Cancelling `progress` stops the extraction with an error.
    static func extractAll(from url: URL, to destination: URL, progress: Progress? = nil) throws {
        let archive = try openArchive(at: url)
        archive.progress = progress
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
        // Under `unrarLock` like every other UnrarKit call. `URKArchive.init`
        // mints a file bookmark, which goes through a synchronous XPC call
        // (LaunchServices → NetFS). When several archives are opened at the
        // same moment, those calls can all block and never return — every
        // thread parked in `bookmarkData(options:)`, the loads behind them
        // stalled. Opening one at a time does not hang.
        let archive = unrarLock.withLock {
            URKArchive.urlIsARAR(url) ? try? URKArchive(url: url) : nil
        }
        guard let archive else {
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
