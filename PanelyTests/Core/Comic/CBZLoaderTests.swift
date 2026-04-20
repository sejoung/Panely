import Testing
import Foundation
@testable import Panely

struct CBZLoaderIntegrationTests {
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
}
