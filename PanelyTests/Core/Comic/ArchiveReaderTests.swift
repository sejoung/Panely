import Testing
import Foundation
import ZIPFoundation
@testable import Panely

struct ArchiveReaderTests {
    /// A ZIP may legally contain two entries with the same path. `archive[path]`
    /// resolves to the first match, so `entryPaths()` must collapse duplicates —
    /// otherwise two pages would alias the same bytes.
    @Test func entryPathsDeduplicatesDuplicatePaths() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let payload = workDir.appendingPathComponent("payload.bin")
        try Fixture.writeFile(payload, bytes: Array(repeating: 0x1, count: 16))

        let zipURL = workDir.appendingPathComponent("dupes.cbz")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "001.jpg", fileURL: payload)
        try archive.addEntry(with: "001.jpg", fileURL: payload) // duplicate path
        try archive.addEntry(with: "002.jpg", fileURL: payload)

        let reader = try ArchiveReader(url: zipURL)
        let paths = await reader.entryPaths()

        #expect(paths == ["001.jpg", "002.jpg"])
    }

    // MARK: - loadData

    /// `loadData(at:)` returns the entry's full uncompressed bytes, exactly.
    @Test func loadDataReturnsFullEntryBytes() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let original = Array(repeating: UInt8(0xAB), count: 4_096)
            + Array(repeating: UInt8(0x12), count: 1_024)
        let payload = workDir.appendingPathComponent("payload.bin")
        try Fixture.writeFile(payload, bytes: original)

        let zipURL = workDir.appendingPathComponent("book.cbz")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "page.bin", fileURL: payload)

        let reader = try ArchiveReader(url: zipURL)
        let data = try await reader.loadData(at: "page.bin")

        #expect(Array(data) == original)
    }

    /// Requesting a path with no matching entry throws `entryNotFound` rather
    /// than returning empty data or crashing.
    @Test func loadDataThrowsEntryNotFoundForMissingPath() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let payload = workDir.appendingPathComponent("payload.bin")
        try Fixture.writeFile(payload, bytes: [1, 2, 3])
        let zipURL = workDir.appendingPathComponent("book.cbz")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "001.jpg", fileURL: payload)

        let reader = try ArchiveReader(url: zipURL)
        await #expect(throws: ArchiveReaderError.self) {
            _ = try await reader.loadData(at: "missing.jpg")
        }
    }

    // MARK: - loadDataPrefix

    /// `loadDataPrefix` stops once it has buffered at least `maxBytes`, so a
    /// large entry returns far less than the whole thing. This also proves the
    /// internal `prefixComplete` sentinel is swallowed — no error leaks out.
    @Test func loadDataPrefixStopsEarlyForLargeEntry() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let fullSize = 2_000_000
        let payload = workDir.appendingPathComponent("big.bin")
        try Data(repeating: 0x7, count: fullSize).write(to: payload)

        let zipURL = workDir.appendingPathComponent("book.cbz")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "big.bin", fileURL: payload)

        let reader = try ArchiveReader(url: zipURL)
        let prefix = try await reader.loadDataPrefix(at: "big.bin", maxBytes: 100)

        #expect(prefix.count >= 100, "must buffer at least maxBytes")
        #expect(prefix.count < fullSize, "must stop early, not read the whole entry")
    }

    /// When the entry is smaller than `maxBytes`, the whole entry comes back
    /// intact (the early-stop branch never fires).
    @Test func loadDataPrefixReturnsWholeEntryWhenSmallerThanMax() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let original = Array(repeating: UInt8(0x5A), count: 64)
        let payload = workDir.appendingPathComponent("small.bin")
        try Fixture.writeFile(payload, bytes: original)

        let zipURL = workDir.appendingPathComponent("book.cbz")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "small.bin", fileURL: payload)

        let reader = try ArchiveReader(url: zipURL)
        let prefix = try await reader.loadDataPrefix(at: "small.bin", maxBytes: 1_000_000)

        #expect(Array(prefix) == original)
    }

    /// The prefix path surfaces the same `entryNotFound` error for a missing path.
    @Test func loadDataPrefixThrowsEntryNotFoundForMissingPath() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let payload = workDir.appendingPathComponent("payload.bin")
        try Fixture.writeFile(payload, bytes: [9, 9, 9])
        let zipURL = workDir.appendingPathComponent("book.cbz")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "001.jpg", fileURL: payload)

        let reader = try ArchiveReader(url: zipURL)
        await #expect(throws: ArchiveReaderError.self) {
            _ = try await reader.loadDataPrefix(at: "missing.jpg", maxBytes: 10)
        }
    }
}
