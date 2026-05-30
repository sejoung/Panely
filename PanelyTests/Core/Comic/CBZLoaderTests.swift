import Testing
import Foundation
import ZIPFoundation
@testable import Panely

struct CBZLoaderIntegrationTests {

    /// A malicious archive whose entry path escapes the extraction root via
    /// `../` must never write outside the destination directory. ZIPFoundation
    /// rejects path-traversal entries on extract; this locks that guarantee in
    /// so a future dependency bump or refactor can't silently regress it.
    @Test func extractAllDoesNotEscapeDestinationViaPathTraversal() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Payload we'll try to smuggle out as a sibling of the extraction root.
        let payload = workDir.appendingPathComponent("payload.png")
        try Fixture.makePNG(width: 4, height: 4).write(to: payload)

        let archiveURL = workDir.appendingPathComponent("evil.cbz")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "../escaped.png", fileURL: payload)

        let dest = workDir.appendingPathComponent("extracted", isDirectory: true)
        // May throw (traversal rejected) or contain it silently — either way
        // the escaped file must not materialize beside the extraction root.
        _ = try? await CBZLoader.extractAll(from: archiveURL, to: dest)

        let escapedSibling = workDir.appendingPathComponent("escaped.png")
        #expect(!FileManager.default.fileExists(atPath: escapedSibling.path))
    }

    @Test func hasNestedArchivesFalseForFlatArchive() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let src = try Fixture.makeTempDir()
        try Fixture.writeFile(src.appendingPathComponent("001.jpg"))
        try Fixture.writeFile(src.appendingPathComponent("002.jpg"))

        let zipURL = workDir.appendingPathComponent("book.cbz")
        try Fixture.zipDirectory(src, to: zipURL)
        try? FileManager.default.removeItem(at: src)

        let hasNested = try await CBZLoader.hasNestedArchives(at: zipURL)
        #expect(hasNested == false)
    }

    @Test func hasNestedArchivesTrueWhenInnerCBZPresent() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Build inner archive
        let innerSrc = try Fixture.makeTempDir()
        try Fixture.writeFile(innerSrc.appendingPathComponent("001.jpg"))
        let innerZip = workDir.appendingPathComponent("_inner_scratch.cbz")
        try Fixture.zipDirectory(innerSrc, to: innerZip)
        try? FileManager.default.removeItem(at: innerSrc)

        // Outer that contains the inner archive
        let outerSrc = try Fixture.makeTempDir()
        try FileManager.default.moveItem(at: innerZip, to: outerSrc.appendingPathComponent("vol01.cbz"))
        let outerZip = workDir.appendingPathComponent("series.cbz")
        try Fixture.zipDirectory(outerSrc, to: outerZip)
        try? FileManager.default.removeItem(at: outerSrc)

        let hasNested = try await CBZLoader.hasNestedArchives(at: outerZip)
        #expect(hasNested == true)
    }

    @Test func loadProducesNaturallySortedPages() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let src = try Fixture.makeTempDir()
        try Fixture.writeFile(src.appendingPathComponent("10.jpg"))
        try Fixture.writeFile(src.appendingPathComponent("02.jpg"))
        try Fixture.writeFile(src.appendingPathComponent("01.jpg"))

        let zipURL = workDir.appendingPathComponent("book.cbz")
        try Fixture.zipDirectory(src, to: zipURL)
        try? FileManager.default.removeItem(at: src)

        let comic = try await CBZLoader.load(from: zipURL)
        #expect(comic.pages.map(\.displayName) == ["01.jpg", "02.jpg", "10.jpg"])
    }

    @Test func extractAllRecursivelyUnpacksNestedArchives() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Inner archive with images
        let innerSrc = try Fixture.makeTempDir()
        try Fixture.writeFile(innerSrc.appendingPathComponent("p1.jpg"))
        let innerZip = workDir.appendingPathComponent("_inner_scratch.cbz")
        try Fixture.zipDirectory(innerSrc, to: innerZip)
        try? FileManager.default.removeItem(at: innerSrc)

        // Outer archive containing the inner archive
        let outerSrc = try Fixture.makeTempDir()
        try FileManager.default.moveItem(at: innerZip, to: outerSrc.appendingPathComponent("vol01.cbz"))
        let outerZip = workDir.appendingPathComponent("series.zip")
        try Fixture.zipDirectory(outerSrc, to: outerZip)
        try? FileManager.default.removeItem(at: outerSrc)

        let dest = workDir.appendingPathComponent("extracted", isDirectory: true)
        try await CBZLoader.extractAll(from: outerZip, to: dest)

        // After recursive extraction: dest/vol01/ folder exists with p1.jpg inside
        var isDir: ObjCBool = false
        let volDir = dest.appendingPathComponent("vol01")
        #expect(FileManager.default.fileExists(atPath: volDir.path, isDirectory: &isDir))
        #expect(isDir.boolValue == true)

        let innerImg = volDir.appendingPathComponent("p1.jpg")
        #expect(FileManager.default.fileExists(atPath: innerImg.path))

        // The original nested archive file should have been removed after extraction
        let residualZip = dest.appendingPathComponent("vol01.cbz")
        #expect(!FileManager.default.fileExists(atPath: residualZip.path))
    }

    @Test func extractAllCapsTotalNestedExtractionSize() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        func makeInnerArchive(named name: String) throws -> URL {
            let innerSrc = try Fixture.makeTempDir()
            defer { try? FileManager.default.removeItem(at: innerSrc) }
            try Data(repeating: 0, count: 700_000)
                .write(to: innerSrc.appendingPathComponent("page.jpg"))
            let innerZip = workDir.appendingPathComponent(name)
            try Fixture.zipDirectory(innerSrc, to: innerZip)
            return innerZip
        }

        let outerSrc = try Fixture.makeTempDir()
        let innerA = try makeInnerArchive(named: "_inner_a.cbz")
        let innerB = try makeInnerArchive(named: "_inner_b.cbz")
        try FileManager.default.moveItem(at: innerA, to: outerSrc.appendingPathComponent("Vol01.cbz"))
        try FileManager.default.moveItem(at: innerB, to: outerSrc.appendingPathComponent("Vol02.cbz"))
        let outerZip = workDir.appendingPathComponent("series.cbz")
        try Fixture.zipDirectory(outerSrc, to: outerZip)
        try? FileManager.default.removeItem(at: outerSrc)

        let dest = workDir.appendingPathComponent("extracted-limit", isDirectory: true)
        await #expect(throws: CBZLoader.LoadError.self) {
            try await CBZLoader.extractAll(
                from: outerZip,
                to: dest,
                maxExtractedBytes: 1_000_000
            )
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    /// A single entry larger than the whole budget must be rejected. This
    /// exercises the size-cap's overflow-safe headroom check (`limit - total`
    /// would underflow when one entry alone exceeds the limit).
    @Test func extractAllRejectsSingleEntryExceedingLimit() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let src = try Fixture.makeTempDir()
        try Data(repeating: 0, count: 2_000_000)
            .write(to: src.appendingPathComponent("big.jpg"))
        let zipURL = workDir.appendingPathComponent("book.cbz")
        try Fixture.zipDirectory(src, to: zipURL)
        try? FileManager.default.removeItem(at: src)

        let dest = workDir.appendingPathComponent("extracted-single", isDirectory: true)
        await #expect(throws: CBZLoader.LoadError.self) {
            try await CBZLoader.extractAll(
                from: zipURL,
                to: dest,
                maxExtractedBytes: 1_000_000
            )
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }
}
