import Testing
import Foundation
@testable import Panely

/// Focused tests for `ReaderTempDirectory`. Most assertions work against
/// synthetic paths in memory — the few that need real disk state (cleanup,
/// stale-entry sweep) create + tear down their own paneltest-prefixed dirs
/// so they don't collide with the production `panely-*` sweep.
@MainActor
struct ReaderTempDirectoryTests {

    // MARK: - adopt / cleanup

    @Test func adoptStoresTheURLAndMarksActive() {
        let tempDir = ReaderTempDirectory()
        #expect(tempDir.isActive == false)

        let url = URL(fileURLWithPath: "/var/folders/T/panely-X")
        tempDir.adopt(url)

        #expect(tempDir.isActive)
        #expect(tempDir.url == url)
    }

    @Test func cleanupRemovesURLReferenceAndDeletesDiskEntry() throws {
        let tempDir = ReaderTempDirectory()
        let realDir = try Fixture.makeTempDir()
        // Stage a marker file so we can prove removeItem actually ran.
        let marker = realDir.appendingPathComponent("marker.txt")
        try Data("x".utf8).write(to: marker)

        tempDir.adopt(realDir)
        tempDir.cleanup()

        #expect(tempDir.isActive == false)
        #expect(FileManager.default.fileExists(atPath: realDir.path) == false)
    }

    @Test func cleanupIsNoOpWhenNothingActive() {
        let tempDir = ReaderTempDirectory()
        tempDir.cleanup() // Must not throw or crash with no URL held.
        #expect(tempDir.isActive == false)
    }

    // MARK: - contains()

    @Test func containsIsFalseWhenNoTempActive() {
        let tempDir = ReaderTempDirectory()
        #expect(tempDir.contains(URL(fileURLWithPath: "/anywhere")) == false)
    }

    @Test func containsMatchesURLsAtOrBelowRoot() {
        let tempDir = ReaderTempDirectory()
        let root = URL(fileURLWithPath: "/var/folders/T/panely-X")
        tempDir.url = root

        #expect(tempDir.contains(root))
        #expect(tempDir.contains(root.appendingPathComponent("Vol01.cbz")))
        #expect(tempDir.contains(root.appendingPathComponent("nested/page.jpg")))
    }

    @Test func containsRejectsSiblingDirectoryWithSamePrefix() {
        // /a/panely-X must not be considered inside /a/panely — the
        // boundary check uses "/" so prefix-only matches are excluded.
        let tempDir = ReaderTempDirectory()
        tempDir.url = URL(fileURLWithPath: "/var/folders/T/panely")

        #expect(tempDir.contains(URL(fileURLWithPath: "/var/folders/T/panely-X/file")) == false)
    }

    // MARK: - makeCandidate uniqueness

    @Test func makeCandidateProducesPanelyPrefixedURLs() {
        let candidate = ReaderTempDirectory.makeCandidate()

        #expect(candidate.lastPathComponent.hasPrefix("panely-"))
        // Lives under the sandbox tmp so cleanupStaleEntries can find it
        // on a future cold start if this session crashes mid-extract.
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(candidate.standardizedFileURL.path.hasPrefix(tmp))
    }

    @Test func makeCandidateProducesUniqueURLsAcrossCalls() {
        let a = ReaderTempDirectory.makeCandidate()
        let b = ReaderTempDirectory.makeCandidate()
        #expect(a != b)
    }

    // MARK: - cleanupStaleEntries

    @Test func cleanupStaleEntriesRemovesOldPanelyDirsAndKeepsFresh() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
        let stale = tmpRoot.appendingPathComponent("panely-stale-\(UUID().uuidString)", isDirectory: true)
        let fresh = tmpRoot.appendingPathComponent("panely-fresh-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        // Backdate the stale dir past the 10-minute sweep threshold.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: stale.path
        )
        defer {
            try? FileManager.default.removeItem(at: stale)
            try? FileManager.default.removeItem(at: fresh)
        }

        ReaderTempDirectory.cleanupStaleEntries()

        #expect(FileManager.default.fileExists(atPath: stale.path) == false)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func cleanupStaleEntriesIgnoresNonPanelyEntries() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
        let unrelated = tmpRoot.appendingPathComponent("paneltest-unrelated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        // Make it stale so the only reason it'd survive is the prefix
        // guard. Without it, the test wouldn't actually prove anything.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: unrelated.path
        )
        defer { try? FileManager.default.removeItem(at: unrelated) }

        ReaderTempDirectory.cleanupStaleEntries()

        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
