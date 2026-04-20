import Testing
import Foundation
@testable import Panely

struct FileNodeTests {
    @Test func folderKindUsesFolderIcon() {
        let url = URL(fileURLWithPath: "/Library")
        let node = FileNode(id: url, url: url, name: "Library", kind: .folder, children: nil)
        #expect(node.iconName == "folder")
    }

    @Test func archiveKindUsesDocZipperIcon() {
        let url = URL(fileURLWithPath: "/Book.cbz")
        let node = FileNode(id: url, url: url, name: "Book", kind: .archive, children: nil)
        #expect(node.iconName == "doc.zipper")
    }

    @Test func archiveExposesCBZExtensionLowercased() {
        let url = URL(fileURLWithPath: "/Book.CBZ")
        let node = FileNode(id: url, url: url, name: "Book", kind: .archive, children: nil)
        #expect(node.fileExtension == "cbz")
    }

    @Test func archiveExposesZipExtension() {
        let url = URL(fileURLWithPath: "/Series.zip")
        let node = FileNode(id: url, url: url, name: "Series", kind: .archive, children: nil)
        #expect(node.fileExtension == "zip")
    }

    @Test func folderHasNilFileExtension() {
        let url = URL(fileURLWithPath: "/Library")
        let node = FileNode(id: url, url: url, name: "Library", kind: .folder, children: nil)
        #expect(node.fileExtension == nil)
    }
}

struct FileNodeLoadTests {
    @Test func includesArchivesAndSubfoldersButNotLooseImages() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Fixture.writeFile(dir.appendingPathComponent("cover.jpg"))
        try Fixture.writeFile(dir.appendingPathComponent("vol01.cbz"))
        let sub = dir.appendingPathComponent("vol02", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Fixture.writeFile(sub.appendingPathComponent("001.jpg"))

        let nodes = await FileNode.loadTree(from: dir, maxDepth: 2)
        let names = nodes.map(\.name)

        #expect(!names.contains("cover.jpg"))
        #expect(names.contains("vol01"))
        #expect(names.contains("vol02"))
    }

    @Test func returnsEmptyForNonExistentDirectory() async {
        let url = URL(fileURLWithPath: "/__panely_definitely_missing_\(UUID().uuidString)")
        let nodes = await FileNode.loadTree(from: url)
        #expect(nodes.isEmpty)
    }

    @Test func sortsAlphanumericallyWithNaturalOrder() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Fixture.writeFile(dir.appendingPathComponent("Vol 10.cbz"))
        try Fixture.writeFile(dir.appendingPathComponent("Vol 1.cbz"))
        try Fixture.writeFile(dir.appendingPathComponent("Vol 2.cbz"))

        let nodes = await FileNode.loadTree(from: dir, maxDepth: 1)
        #expect(nodes.map(\.name) == ["Vol 1", "Vol 2", "Vol 10"])
    }

    @Test func loadTreeAttachesExtensionToArchives() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Fixture.writeFile(dir.appendingPathComponent("vol01.cbz"))
        try Fixture.writeFile(dir.appendingPathComponent("vol02.zip"))
        let sub = dir.appendingPathComponent("vol03", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Fixture.writeFile(sub.appendingPathComponent("001.jpg"))

        let nodes = await FileNode.loadTree(from: dir, maxDepth: 2)
        let nodeByName = Dictionary(uniqueKeysWithValues: nodes.map { ($0.name, $0) })

        #expect(nodeByName["vol01"]?.fileExtension == "cbz")
        #expect(nodeByName["vol02"]?.fileExtension == "zip")
        #expect(nodeByName["vol03"]?.fileExtension == nil) // folder has no extension
    }
}
