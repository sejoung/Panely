import Testing
import Foundation
@testable import Panely

struct FavoriteBookTests {
    @Test func codableRoundTripPreservesAllFields() throws {
        let original = FavoriteBook(
            id: UUID(),
            path: "/Users/demo/Comics/Vol01.cbz",
            title: "Vol01",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            bookmarkData: Data([0x01, 0x02, 0x03, 0x04]),
            isDirectory: false
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FavoriteBook.self, from: encoded)

        #expect(decoded.id == original.id)
        #expect(decoded.path == original.path)
        #expect(decoded.title == original.title)
        #expect(decoded.addedAt == original.addedAt)
        #expect(decoded.bookmarkData == original.bookmarkData)
        #expect(decoded.isDirectory == original.isDirectory)
    }

    @Test func legacyJSONWithoutIsDirectoryDecodesAsFile() throws {
        // Forward-compat guarantee: if a future schema bump removes or renames
        // `isDirectory`, old stored favorites must still decode cleanly.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "path": "/legacy.cbz",
          "title": "Legacy",
          "addedAt": 757382400.0,
          "bookmarkData": "AQIDBA=="
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FavoriteBook.self, from: json)
        #expect(decoded.isDirectory == false)
        #expect(decoded.path == "/legacy.cbz")
        #expect(decoded.bookmarkData == Data([0x01, 0x02, 0x03, 0x04]))
    }

    @Test func folderItemUsesFolderIcon() {
        let item = FavoriteBook(
            id: UUID(),
            path: "/Library",
            title: "Library",
            addedAt: Date(),
            bookmarkData: Data(),
            isDirectory: true
        )
        #expect(item.iconName == "folder")
    }

    @Test func archiveItemUsesDocZipperIcon() {
        let item = FavoriteBook(
            id: UUID(),
            path: "/Book.cbz",
            title: "Book",
            addedAt: Date(),
            bookmarkData: Data(),
            isDirectory: false
        )
        #expect(item.iconName == "doc.zipper")
    }
}
