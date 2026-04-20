import Testing
import Foundation
@testable import Panely

struct FolderLoaderIntegrationTests {
    @Test func filtersOutNonImageFiles() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Fixture.writeFile(dir.appendingPathComponent("page1.jpg"))
        try Fixture.writeFile(dir.appendingPathComponent("page2.png"))
        try Fixture.writeFile(dir.appendingPathComponent("readme.txt"))
        try Fixture.writeFile(dir.appendingPathComponent("config.json"))

        let source = try FolderLoader.load(from: dir)
        let names = Set(source.pages.map(\.displayName))
        #expect(names == ["page1.jpg", "page2.png"])
    }

    @Test func naturalSortsByFilename() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Fixture.writeFile(dir.appendingPathComponent("page10.jpg"))
        try Fixture.writeFile(dir.appendingPathComponent("page2.jpg"))
        try Fixture.writeFile(dir.appendingPathComponent("page1.jpg"))

        let source = try FolderLoader.load(from: dir)
        let names = source.pages.map(\.displayName)
        #expect(names == ["page1.jpg", "page2.jpg", "page10.jpg"])
    }

    @Test func skipsHiddenFiles() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Fixture.writeFile(dir.appendingPathComponent("001.jpg"))
        try Fixture.writeFile(dir.appendingPathComponent(".DS_Store"))
        try Fixture.writeFile(dir.appendingPathComponent("._thumbnail.jpg"))

        let source = try FolderLoader.load(from: dir)
        let names = source.pages.map(\.displayName)
        #expect(names.contains("001.jpg"))
        #expect(!names.contains(".DS_Store"))
    }

    @Test func titleDerivedFromFolderName() throws {
        let parent = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }

        let dir = parent.appendingPathComponent("OnePiece", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Fixture.writeFile(dir.appendingPathComponent("001.jpg"))

        let source = try FolderLoader.load(from: dir)
        #expect(source.title == "OnePiece")
    }
}
