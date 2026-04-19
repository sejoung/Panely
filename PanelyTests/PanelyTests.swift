import Testing
import Foundation
@testable import Panely

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
