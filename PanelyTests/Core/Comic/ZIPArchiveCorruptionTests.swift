import Testing
import Foundation
import ZIPFoundation
@testable import Panely

/// Damaged ZIPs: the reader refuses what it can't open and never hands a
/// damaged entry back as if it were the page's real bytes.
struct ZIPArchiveCorruptionTests {
    @Test func garbageFileCannotBeOpened() throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = workDir.appendingPathComponent("garbage.cbz")
        try Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: url)

        #expect(throws: ArchiveReaderError.cannotOpen(url)) {
            _ = try ZIPArchiveReader(url: url)
        }
    }

    /// A download cut short loses the central directory at the end of the
    /// file: the archive must refuse to open rather than list nothing.
    @Test func truncatedArchiveCannotBeOpened() throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let zipURL = workDir.appendingPathComponent("book.cbz")
        let archive = try Archive(url: zipURL, accessMode: .create)
        for i in 0..<4 {
            try Self.add(Data(repeating: UInt8(i), count: 2_000), as: "\(i).png", to: archive)
        }
        let bytes = try Data(contentsOf: zipURL)
        let truncated = workDir.appendingPathComponent("truncated.cbz")
        try bytes.prefix(bytes.count / 2).write(to: truncated)

        #expect(throws: ArchiveReaderError.cannotOpen(truncated)) {
            _ = try ZIPArchiveReader(url: truncated)
        }
    }

    /// A flipped byte inside a *stored* entry is only detectable by its CRC.
    /// A full read must fail rather than hand back silently corrupt pixels.
    @Test func corruptStoredEntryFailsItsChecksum() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let marker = Array("PANELY-PAYLOAD-".utf8)
        let payload = Data((0..<200).flatMap { _ in marker })
        let zipURL = workDir.appendingPathComponent("book.cbz")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try Self.add(payload, as: "001.png", to: archive)
        try Self.add(Data(repeating: 0x42, count: 512), as: "002.png", to: archive)

        var bytes = try Data(contentsOf: zipURL)
        let range = try #require(bytes.range(of: Data(marker)))
        bytes[range.lowerBound + 3] ^= 0xFF
        try bytes.write(to: zipURL)

        let reader = try ZIPArchiveReader(url: zipURL)
        await #expect(throws: Archive.ArchiveError.invalidCRC32) {
            _ = try await reader.loadData(at: "001.png")
        }
        // The intact neighbour still reads.
        #expect(try await reader.loadData(at: "002.png") == Data(repeating: 0x42, count: 512))
    }

    /// A stored (uncompressed) entry, so its bytes appear verbatim in the file.
    private static func add(_ data: Data, as path: String, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .none,
            provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        )
    }
}
