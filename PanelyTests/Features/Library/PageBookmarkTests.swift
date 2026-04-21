import Testing
import Foundation
@testable import Panely

struct PageBookmarkTests {
    @Test func codableRoundTripPreservesAllFields() throws {
        let original = PageBookmark(
            id: UUID(),
            pageIndex: 42,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PageBookmark.self, from: encoded)

        #expect(decoded == original)
    }

    @Test func defaultInitAssignsFreshIDAndDate() {
        let before = Date()
        let bookmark = PageBookmark(pageIndex: 7)
        let after = Date()

        #expect(bookmark.pageIndex == 7)
        #expect(bookmark.createdAt >= before)
        #expect(bookmark.createdAt <= after)
    }
}
