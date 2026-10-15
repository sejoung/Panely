import Testing
import Foundation
import ZIPFoundation
@testable import Panely

/// `ZIPArchiveReader` resolves paths through an index built once per archive
/// instead of ZIPFoundation's linear `archive[path]` scan. These tests pin
/// that the index is a pure speed-up: every lookup returns exactly what the
/// linear first-match lookup on a fresh `Archive` returns, over an archive
/// that mixes the awkward cases (nested folders, explicit directory entries,
/// non-ASCII names, a duplicated path, stored + deflated, empty and
/// multi-chunk entries).
struct ZIPArchiveIndexEquivalenceTests {
    /// The file entries of `makeMixedArchive`, in archive order with the
    /// duplicate collapsed — what `entryPaths()` returned before the index.
    /// Deliberately not sorted: page order is `ArchiveLoader`'s job.
    static let expectedPaths = [
        "Vol 1/002.png",
        "Vol 1/001.png",
        "한글/페이지 01.jpg",
        "dup.jpg",
        "deep/a/b/c/d.jpg",
        "Café/ñ.png",
        "empty.bin",
        "big.bin",
    ]

    @Test func entryPathsKeepArchiveOrderAndSkipDirectories() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let zipURL = try Self.makeMixedArchive(in: workDir)

        let reader = try ZIPArchiveReader(url: zipURL)
        #expect(await reader.entryPaths() == Self.expectedPaths)
        // Asked twice: the cached index answers the same.
        #expect(await reader.entryPaths() == Self.expectedPaths)
    }

    @Test func everyIndexedLookupMatchesALinearLookup() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let zipURL = try Self.makeMixedArchive(in: workDir)

        let reader = try ZIPArchiveReader(url: zipURL)
        // Read in reverse so no lookup benefits from following the previous one.
        for path in await reader.entryPaths().reversed() {
            let indexed = try await reader.loadData(at: path)
            let linear = try Self.linearRead(zipURL, path: path)
            #expect(indexed == linear, "bytes differ for \(path)")
        }
    }

    /// A prefix is the head of the entry: at least `maxBytes` of it (or all
    /// of it), byte-identical to the full read.
    @Test func prefixReadsAreHeadsOfTheFullEntry() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let zipURL = try Self.makeMixedArchive(in: workDir)

        let reader = try ZIPArchiveReader(url: zipURL)
        for path in Self.expectedPaths {
            let full = try Self.linearRead(zipURL, path: path)
            for maxBytes in [1, 100, 16_384, 70_000, 10_000_000] {
                let prefix = try await reader.loadDataPrefix(at: path, maxBytes: maxBytes)
                #expect(prefix.count >= min(maxBytes, full.count), "\(path) prefix(\(maxBytes)) too short: \(prefix.count)")
                #expect(prefix == full.prefix(prefix.count), "\(path) prefix(\(maxBytes)) is not the entry's head")
            }
        }
    }

    /// Directory entries are not pages and can't be read as one.
    @Test func directoryEntriesAreNotAddressable() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let zipURL = try Self.makeMixedArchive(in: workDir)

        let reader = try ZIPArchiveReader(url: zipURL)
        await #expect(throws: ArchiveReaderError.entryNotFound("Vol 1/")) {
            _ = try await reader.loadData(at: "Vol 1/")
        }
    }

    // MARK: - Fixture

    /// Archive order matters: `Vol 1/002.png` precedes `001.png`, the
    /// duplicate `dup.jpg` comes after other entries, and directory entries
    /// are interleaved with files.
    static func makeMixedArchive(in dir: URL) throws -> URL {
        let zipURL = dir.appendingPathComponent("mixed.cbz")
        let archive = try Archive(url: zipURL, accessMode: .create)

        try addDirectory("Vol 1/", to: archive)
        try add(bytes(seed: 1, count: 3_000), as: "Vol 1/002.png", compression: .deflate, to: archive)
        try add(bytes(seed: 2, count: 2_000), as: "Vol 1/001.png", compression: .none, to: archive)
        try addDirectory("한글/", to: archive)
        try add(bytes(seed: 3, count: 1_000), as: "한글/페이지 01.jpg", compression: .deflate, to: archive)
        try add(Data(repeating: 0xC1, count: 64), as: "dup.jpg", compression: .none, to: archive)
        try addDirectory("deep/a/b/c/", to: archive)
        try add(bytes(seed: 4, count: 500), as: "deep/a/b/c/d.jpg", compression: .deflate, to: archive)
        try add(Data(repeating: 0xD2, count: 96), as: "dup.jpg", compression: .none, to: archive) // duplicate path
        try add(bytes(seed: 5, count: 700), as: "Café/ñ.png", compression: .deflate, to: archive)
        try add(Data(), as: "empty.bin", compression: .none, to: archive)
        // Several extract chunks (ZIPFoundation reads 16 KB at a time), and
        // incompressible so deflate doesn't collapse it into one.
        try add(bytes(seed: 6, count: 300_000), as: "big.bin", compression: .deflate, to: archive)
        return zipURL
    }

    /// Reference read: a fresh `Archive`, ZIPFoundation's linear first-match
    /// `archive[path]`, a full CRC-checked extract.
    static func linearRead(_ url: URL, path: String) throws -> Data {
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try #require(archive[path], "no entry \(path)")
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    static func add(_ data: Data, as path: String, compression: CompressionMethod, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compression,
            provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        )
    }

    static func addDirectory(_ path: String, to archive: Archive) throws {
        try archive.addEntry(with: path, type: .directory, uncompressedSize: Int64(0), provider: { (_: Int64, _: Int) in Data() })
    }

    /// Deterministic pseudo-random bytes (xorshift), distinct per seed.
    static func bytes(seed: UInt64, count: Int) -> Data {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        var out = Data(capacity: count)
        for _ in 0..<count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            out.append(UInt8(truncatingIfNeeded: state))
        }
        return out
    }
}
