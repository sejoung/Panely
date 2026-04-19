import Testing
import Foundation
import ZIPFoundation
@testable import Panely

// MARK: - Test fixtures helpers

private enum Fixture {
    static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("panely-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func writeFile(_ url: URL, bytes: [UInt8] = [0]) throws -> URL {
        try Data(bytes).write(to: url)
        return url
    }

    static func zipDirectory(_ sourceDir: URL, to zipURL: URL) throws {
        try FileManager.default.zipItem(at: sourceDir, to: zipURL, shouldKeepParent: false)
    }
}

// MARK: - ComicPage

struct ComicPageTests {
    @Test func createsUniqueIDPerInstance() {
        let url = URL(fileURLWithPath: "/tmp/sample.cbz")
        let a = ComicPage(source: .file(url), displayName: "sample")
        let b = ComicPage(source: .file(url), displayName: "sample")
        #expect(a.id != b.id)
    }

    @Test func displayNameIsPreserved() {
        let page = ComicPage(
            source: .file(URL(fileURLWithPath: "/tmp/x.cbz")),
            displayName: "Vol 01"
        )
        #expect(page.displayName == "Vol 01")
    }
}

// MARK: - ComicSource

struct ComicSourceTests {
    @Test func emptySourceIsEmpty() {
        let empty = ComicSource.empty
        #expect(empty.isEmpty)
        #expect(empty.pageCount == 0)
        #expect(empty.title.isEmpty)
    }

    @Test func pageCountReflectsPages() {
        let pages = (1...5).map { i in
            ComicPage(
                source: .file(URL(fileURLWithPath: "/p\(i)")),
                displayName: "\(i)"
            )
        }
        let source = ComicSource(title: "Test", pages: pages)
        #expect(source.pageCount == 5)
        #expect(source.isEmpty == false)
        #expect(source.title == "Test")
    }
}

// MARK: - RecentItem

struct RecentItemTests {
    @Test func codableRoundTripPreservesAllFields() throws {
        let original = RecentItem(
            id: UUID(),
            path: "/Users/demo/Comics/Vol01.cbz",
            title: "Vol01",
            openedAt: Date(timeIntervalSince1970: 1_700_000_000),
            bookmarkData: Data([0x01, 0x02, 0x03, 0x04]),
            isDirectory: false
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecentItem.self, from: encoded)

        #expect(decoded.id == original.id)
        #expect(decoded.path == original.path)
        #expect(decoded.title == original.title)
        #expect(decoded.openedAt == original.openedAt)
        #expect(decoded.bookmarkData == original.bookmarkData)
        #expect(decoded.isDirectory == original.isDirectory)
    }

    @Test func legacyJSONWithoutIsDirectoryDecodesAsFile() throws {
        // Simulate data stored before the isDirectory field was added
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "path": "/legacy.cbz",
          "title": "Legacy",
          "openedAt": 757382400.0,
          "bookmarkData": "AQIDBA=="
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RecentItem.self, from: json)
        #expect(decoded.isDirectory == false)
        #expect(decoded.path == "/legacy.cbz")
        #expect(decoded.bookmarkData == Data([0x01, 0x02, 0x03, 0x04]))
    }

    @Test func folderItemUsesFolderIcon() {
        let item = RecentItem(
            id: UUID(),
            path: "/Library",
            title: "Library",
            openedAt: Date(),
            bookmarkData: Data(),
            isDirectory: true
        )
        #expect(item.iconName == "folder")
    }

    @Test func archiveItemUsesBookIcon() {
        let item = RecentItem(
            id: UUID(),
            path: "/Book.cbz",
            title: "Book",
            openedAt: Date(),
            bookmarkData: Data(),
            isDirectory: false
        )
        #expect(item.iconName == "book.closed")
    }
}

// MARK: - ReadingDirection

struct ReadingDirectionTests {
    @Test func leftToRightIsNotRTL() {
        #expect(ReadingDirection.leftToRight.isRTL == false)
    }

    @Test func rightToLeftIsRTL() {
        #expect(ReadingDirection.rightToLeft.isRTL == true)
    }

    @Test func rawValuesRoundTrip() {
        for direction in ReadingDirection.allCases {
            let restored = ReadingDirection(rawValue: direction.rawValue)
            #expect(restored == direction)
        }
    }
}

// MARK: - FileNode

struct FileNodeTests {
    @Test func folderKindUsesFolderIcon() {
        let url = URL(fileURLWithPath: "/Library")
        let node = FileNode(id: url, url: url, name: "Library", kind: .folder, children: nil)
        #expect(node.iconName == "folder")
    }

    @Test func archiveKindUsesBookIcon() {
        let url = URL(fileURLWithPath: "/Book.cbz")
        let node = FileNode(id: url, url: url, name: "Book", kind: .archive, children: nil)
        #expect(node.iconName == "book.closed")
    }
}

// MARK: - Layout and Fit enums

struct PageLayoutTests {
    @Test func rawValuesAreStable() {
        #expect(PageLayout.single.rawValue == "single")
        #expect(PageLayout.double.rawValue == "double")
        #expect(PageLayout.vertical.rawValue == "vertical")
    }
}

struct FitModeTests {
    @Test func rawValuesAreStable() {
        #expect(FitMode.fitScreen.rawValue == "fitScreen")
        #expect(FitMode.fitWidth.rawValue == "fitWidth")
    }
}

// MARK: - Loader supported extensions (pure config)

struct LoaderExtensionTests {
    @Test func folderLoaderSupportsCommonImageFormats() {
        let exts = FolderLoader.supportedExtensions
        #expect(exts.contains("jpg"))
        #expect(exts.contains("png"))
        #expect(exts.contains("webp"))
        #expect(exts.contains("heic"))
        #expect(exts.contains("gif"))
    }

    @Test func cbzLoaderSupportsArchiveExtensions() {
        let exts = CBZLoader.supportedExtensions
        #expect(exts.contains("cbz"))
        #expect(exts.contains("zip"))
    }
}

// MARK: - Natural sort behaviour (foundation contract Panely relies on)

struct NaturalSortTests {
    @Test func numericSegmentsSortNumerically() {
        let names = ["10.cbz", "2.cbz", "1.cbz", "20.cbz"]
        let sorted = names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        #expect(sorted == ["1.cbz", "2.cbz", "10.cbz", "20.cbz"])
    }

    @Test func mixedPrefixSortedLexicallyAcrossPrefix() {
        let names = ["Vol 10.cbz", "Vol 2.cbz", "Vol 1.cbz"]
        let sorted = names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        #expect(sorted == ["Vol 1.cbz", "Vol 2.cbz", "Vol 10.cbz"])
    }
}

// MARK: - PositionKey (stable key across temp extractions)

struct PositionKeyTests {
    @Test func directOpenReturnsPlainPath() {
        let url = URL(fileURLWithPath: "/Comics/Vol01.cbz")
        let key = PositionKey.make(for: url, opened: nil, tempRoot: nil)
        #expect(key == "/Comics/Vol01.cbz")
    }

    @Test func tempBackedVolumeUsesCompoundKey() {
        let opened = URL(fileURLWithPath: "/Comics/series.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")
        let source = URL(fileURLWithPath: "/tmp/panely-A/Vol01.cbz")

        let key = PositionKey.make(for: source, opened: opened, tempRoot: temp)
        #expect(key == "/Comics/series.zip#Vol01.cbz")
    }

    @Test func tempRootMatchesOpenedPathDirectly() {
        let opened = URL(fileURLWithPath: "/Comics/series.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")

        let key = PositionKey.make(for: temp, opened: opened, tempRoot: temp)
        #expect(key == "/Comics/series.zip")
    }

    @Test func outsideTempFallsBackToSourcePath() {
        let opened = URL(fileURLWithPath: "/Comics/series.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")
        let source = URL(fileURLWithPath: "/other/Vol01.cbz")

        let key = PositionKey.make(for: source, opened: opened, tempRoot: temp)
        #expect(key == "/other/Vol01.cbz")
    }

    @Test func deeplyNestedPathProducesRelativeSegments() {
        let opened = URL(fileURLWithPath: "/Comics/super.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")
        let source = URL(fileURLWithPath: "/tmp/panely-A/middle/Vol01")

        let key = PositionKey.make(for: source, opened: opened, tempRoot: temp)
        #expect(key == "/Comics/super.zip#middle/Vol01")
    }

    @Test func siblingPathWithSimilarPrefixIsNotCollapsed() {
        let opened = URL(fileURLWithPath: "/Comics/series.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")
        let source = URL(fileURLWithPath: "/tmp/panely-Abc/Vol01.cbz")

        let key = PositionKey.make(for: source, opened: opened, tempRoot: temp)
        #expect(key == "/tmp/panely-Abc/Vol01.cbz")
    }
}

// MARK: - FolderLoader integration (real temp directories)

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

// MARK: - FileNode.loadTree

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
}

// MARK: - CBZLoader integration (with real zip fixtures)

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
