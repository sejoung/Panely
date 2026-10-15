import Foundation
import ZIPFoundation

actor ZIPArchiveReader: ArchiveReader {
    nonisolated let archiveURL: URL
    private let archive: Archive

    /// File entries by path, plus their archive order. Built once on first
    /// use: ZIPFoundation's `archive[path]` is a linear scan that re-reads
    /// central-directory records from disk, so resolving every page through
    /// it made a whole-book pass (dimension pre-pass, thumbnails) O(n²) in
    /// entry reads.
    private var entryIndex: EntryIndex?

    private struct EntryIndex {
        var byPath: [String: Entry] = [:]
        var orderedPaths: [String] = []
    }

    /// Upper bound for the up-front buffer reservation in `loadData`. The
    /// declared size comes from the archive header, so a corrupt or hostile
    /// value must not turn into a huge allocation before a byte is read —
    /// past this the buffer simply grows as chunks arrive.
    private static let maxReservedBytes: UInt64 = 256 * 1024 * 1024

    init(url: URL) throws {
        self.archiveURL = url
        do {
            self.archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ArchiveReaderError.cannotOpen(url)
        }
    }

    func entryPaths() -> [String] {
        index().orderedPaths
    }

    func loadData(at path: String) throws -> Data {
        try Task.checkCancellation()
        let entry = try entry(at: path)
        var buffer = Data()
        buffer.reserveCapacity(Int(min(entry.uncompressedSize, Self.maxReservedBytes)))
        let checksum = try archive.extract(entry) { chunk in
            // Stop inflating a page nobody is waiting for any more — paged
            // navigation and scrolling cancel superseded decodes.
            try Task.checkCancellation()
            buffer.append(chunk)
        }
        // `extract` only computes the CRC; comparing it is the caller's job
        // (ZIPFoundation's own `unzipItem` does the same). Without this a
        // damaged entry came back as silently corrupt bytes.
        guard checksum == entry.checksum else {
            throw Archive.ArchiveError.invalidCRC32
        }
        return buffer
    }

    /// Reads at most `maxBytes` of an entry by stopping the extract early.
    /// Used by `ImageLoader.dimensions` to decode the image header without
    /// decompressing the whole entry (a 5 MB image otherwise costs the full
    /// 5 MB of disk + decompression just to read width/height).
    /// `skipCRC32: true` because we're not reading the whole stream and
    /// the checksum can't be validated.
    func loadDataPrefix(at path: String, maxBytes: Int) throws -> Data {
        try Task.checkCancellation()
        let entry = try entry(at: path)
        var buffer = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: true) { chunk in
                buffer.append(chunk)
                if buffer.count >= maxBytes {
                    throw ArchiveReaderError.prefixComplete
                }
            }
        } catch ArchiveReaderError.prefixComplete {
            // expected — we got our prefix and bailed early
        }
        return buffer
    }

    private func entry(at path: String) throws -> Entry {
        guard let entry = index().byPath[path] else {
            throw ArchiveReaderError.entryNotFound(path)
        }
        return entry
    }

    private func index() -> EntryIndex {
        if let entryIndex { return entryIndex }
        // Dedupe by path, keeping the *first* entry: two entries sharing a
        // path would otherwise produce two pages that both read the same
        // bytes. Collapsing to one path per unique name keeps page → bytes
        // addressing unambiguous (and matches what `archive[path]`, a
        // first-match scan, used to resolve to).
        var built = EntryIndex()
        for entry in archive where entry.type == .file {
            guard built.byPath[entry.path] == nil else { continue }
            built.byPath[entry.path] = entry
            built.orderedPaths.append(entry.path)
        }
        entryIndex = built
        return built
    }
}
