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
}
