import Testing
import Foundation
@testable import Panely

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
