import Testing
import Foundation
@testable import Panely

@MainActor
struct PageBookmarksStoreTests {

    @Test func togglingPageBookmarkAddsThenRemovesIt() {
        let store = freshStore()
        let key = "book-\(UUID().uuidString)"

        #expect(store.isPageBookmarked(key: key, pageIndex: 5) == false)

        let added = store.togglePageBookmark(key: key, pageIndex: 5)
        #expect(added == true)
        #expect(store.isPageBookmarked(key: key, pageIndex: 5) == true)

        let removed = store.togglePageBookmark(key: key, pageIndex: 5)
        #expect(removed == false)
        #expect(store.isPageBookmarked(key: key, pageIndex: 5) == false)
    }

    @Test func pageBookmarksSortByPageIndex() {
        let store = freshStore()
        let key = "book-\(UUID().uuidString)"

        store.togglePageBookmark(key: key, pageIndex: 10)
        store.togglePageBookmark(key: key, pageIndex: 3)
        store.togglePageBookmark(key: key, pageIndex: 7)

        let list = store.pageBookmarks(forKey: key).map(\.pageIndex)
        #expect(list == [3, 7, 10])
    }

    @Test func bookmarksForDifferentKeysDoNotInteract() {
        let store = freshStore()
        let keyA = "book-A-\(UUID().uuidString)"
        let keyB = "book-B-\(UUID().uuidString)"

        store.togglePageBookmark(key: keyA, pageIndex: 3)
        store.togglePageBookmark(key: keyB, pageIndex: 5)

        #expect(store.pageBookmarks(forKey: keyA).map(\.pageIndex) == [3])
        #expect(store.pageBookmarks(forKey: keyB).map(\.pageIndex) == [5])
    }

    @Test func nextBookmarkReturnsFirstAfterGivenIndex() {
        let store = freshStore()
        let key = "book-\(UUID().uuidString)"
        for p in [3, 7, 10] { _ = store.togglePageBookmark(key: key, pageIndex: p) }

        #expect(store.nextBookmark(forKey: key, after: 0)?.pageIndex == 3)
        #expect(store.nextBookmark(forKey: key, after: 3)?.pageIndex == 7)
        #expect(store.nextBookmark(forKey: key, after: 7)?.pageIndex == 10)
        #expect(store.nextBookmark(forKey: key, after: 10) == nil)
    }

    @Test func previousBookmarkReturnsLastBeforeGivenIndex() {
        let store = freshStore()
        let key = "book-\(UUID().uuidString)"
        for p in [3, 7, 10] { _ = store.togglePageBookmark(key: key, pageIndex: p) }

        #expect(store.previousBookmark(forKey: key, before: 11)?.pageIndex == 10)
        #expect(store.previousBookmark(forKey: key, before: 10)?.pageIndex == 7)
        #expect(store.previousBookmark(forKey: key, before: 7)?.pageIndex == 3)
        #expect(store.previousBookmark(forKey: key, before: 3) == nil)
    }

    @Test func emptyBookmarkListReturnsNilNeighbors() {
        let store = freshStore()
        let key = "empty-\(UUID().uuidString)"

        #expect(store.nextBookmark(forKey: key, after: 0) == nil)
        #expect(store.previousBookmark(forKey: key, before: 100) == nil)
    }

    @Test func removePageBookmarkByIDRemovesOnlyThatOne() {
        let store = freshStore()
        let key = "book-\(UUID().uuidString)"

        _ = store.togglePageBookmark(key: key, pageIndex: 3)
        _ = store.togglePageBookmark(key: key, pageIndex: 7)
        guard let target = store.pageBookmarks(forKey: key).first(where: { $0.pageIndex == 3 }) else {
            Issue.record("expected a bookmark at pageIndex 3")
            return
        }

        store.removePageBookmark(forKey: key, id: target.id)

        #expect(store.pageBookmarks(forKey: key).map(\.pageIndex) == [7])
    }

    @Test func removingLastBookmarkDropsTheKey() {
        let store = freshStore()
        let key = "book-\(UUID().uuidString)"

        _ = store.togglePageBookmark(key: key, pageIndex: 1)
        _ = store.togglePageBookmark(key: key, pageIndex: 1) // remove via toggle

        // With no remaining bookmarks, the dictionary entry must be dropped so
        // the persisted blob stays compact instead of accumulating empty keys.
        #expect(store.pageBookmarksByBook[key] == nil)
    }

    @Test func pageBookmarksPersistAcrossStoreInstances() {
        let key = "book-\(UUID().uuidString)"
        let defaults = InMemoryKeyValueStore()
        let writer = PageBookmarksStore(defaults: defaults)
        _ = writer.togglePageBookmark(key: key, pageIndex: 42)

        // A brand-new store must read what the previous one wrote through
        // the key-value store — proves the load/save symmetry.
        let reader = PageBookmarksStore(defaults: defaults)
        #expect(reader.isPageBookmarked(key: key, pageIndex: 42) == true)
    }

    // MARK: - Bulk removal

    @Test func removeAllPageBookmarksForKeyClearsOnlyThatBook() {
        let store = freshStore()
        for p in [1, 2, 3] { _ = store.togglePageBookmark(key: "/lib/A.cbz", pageIndex: p) }
        _ = store.togglePageBookmark(key: "/lib/B.cbz", pageIndex: 9)

        store.removeAllPageBookmarks(forKey: "/lib/A.cbz")

        #expect(store.pageBookmarksByBook["/lib/A.cbz"] == nil)
        #expect(store.pageBookmarks(forKey: "/lib/B.cbz").map(\.pageIndex) == [9])
    }

    @Test func removeAllClearsEveryBookAndPersists() {
        let defaults = InMemoryKeyValueStore()
        let store = PageBookmarksStore(defaults: defaults)
        _ = store.togglePageBookmark(key: "/lib/A.cbz", pageIndex: 1)
        _ = store.togglePageBookmark(key: "/lib/B.cbz", pageIndex: 2)
        store.setBookRef(makeRef(title: "A", path: "/lib/A.cbz"), forKey: "/lib/A.cbz")
        #expect(store.totalBookmarkCount == 2)

        store.removeAll()

        #expect(store.totalBookmarkCount == 0)
        let reloaded = PageBookmarksStore(defaults: defaults)
        #expect(reloaded.pageBookmarksByBook.isEmpty)
        #expect(reloaded.bookRef(forKey: "/lib/A.cbz") == nil)
    }

    // MARK: - Book references

    @Test func bookRefPersistsAndIsDroppedWithTheLastBookmark() {
        let defaults = InMemoryKeyValueStore()
        let store = PageBookmarksStore(defaults: defaults)
        let key = "/lib/A.cbz"
        _ = store.togglePageBookmark(key: key, pageIndex: 4)
        store.setBookRef(makeRef(title: "A", path: key), forKey: key)

        #expect(PageBookmarksStore(defaults: defaults).bookRef(forKey: key)?.title == "A")

        _ = store.togglePageBookmark(key: key, pageIndex: 4) // removes the last one

        #expect(store.bookRef(forKey: key) == nil)
        #expect(PageBookmarksStore(defaults: defaults).bookRef(forKey: key) == nil)
    }

    @Test func bookRefIsIgnoredForBookWithoutBookmarks() {
        let store = freshStore()
        store.setBookRef(makeRef(title: "Ghost", path: "/lib/Ghost.cbz"), forKey: "/lib/Ghost.cbz")
        #expect(store.bookRef(forKey: "/lib/Ghost.cbz") == nil)
    }

    @Test func titleFallsBackToKeyForBookmarksWithoutRef() {
        let store = freshStore()
        #expect(store.title(forKey: "/lib/Series/Vol 03.cbz") == "Vol 03")
        // zip-in-zip keys are `outer#inner`.
        #expect(store.title(forKey: "/lib/Series.zip#Vol02/pages") == "Series · pages")
    }

    // MARK: - Cross-book listing

    @Test func bookmarkedBooksExcludesCurrentAndOrdersByMostRecentBookmark() {
        let store = freshStore()
        let old = Date(timeIntervalSince1970: 1_000)
        let mid = Date(timeIntervalSince1970: 2_000)
        let new = Date(timeIntervalSince1970: 3_000)
        store.pageBookmarksByBook = [
            "/lib/Old.cbz": [PageBookmark(pageIndex: 1, createdAt: old)],
            "/lib/New.cbz": [
                PageBookmark(pageIndex: 2, createdAt: old),
                PageBookmark(pageIndex: 8, createdAt: new),
            ],
            "/lib/Current.cbz": [PageBookmark(pageIndex: 5, createdAt: mid)],
        ]

        let books = store.bookmarkedBooks(excluding: "/lib/Current.cbz")

        #expect(books.map(\.title) == ["New", "Old"])
        // Volume files are often just "Vol 03" — the folder disambiguates.
        #expect(books.first?.qualifiedTitle == "lib / New")
        #expect(books.first?.bookmarks.map(\.pageIndex) == [2, 8])
        #expect(store.bookmarkedBooks().count == 3)
    }

    @Test func moveBookmarksMergesIntoTheNewKey() {
        let store = freshStore()
        _ = store.togglePageBookmark(key: "/old/A.cbz", pageIndex: 3)
        _ = store.togglePageBookmark(key: "/old/A.cbz", pageIndex: 7)
        store.setBookRef(makeRef(title: "A", path: "/old/A.cbz"), forKey: "/old/A.cbz")
        _ = store.togglePageBookmark(key: "/new/A.cbz", pageIndex: 7)

        store.moveBookmarks(fromKey: "/old/A.cbz", toKey: "/new/A.cbz")

        #expect(store.pageBookmarksByBook["/old/A.cbz"] == nil)
        // Page 7 was bookmarked under both keys — it must not be listed twice.
        #expect(store.pageBookmarks(forKey: "/new/A.cbz").map(\.pageIndex) == [3, 7])
        #expect(store.bookRef(forKey: "/new/A.cbz")?.title == "A")
    }

    @Test func migrateSourcePathCarriesBookRefToTheNewKey() {
        let store = freshStore()
        let oldKey = "/old/Series.zip#Vol02"
        _ = store.togglePageBookmark(key: oldKey, pageIndex: 3)
        store.setBookRef(
            makeRef(title: "Series · Vol02", path: "/old/Series.zip", innerPath: "Vol02"),
            forKey: oldKey
        )

        store.migrateSourcePath(from: "/old/Series.zip", to: "/new/Series.zip")

        let newKey = "/new/Series.zip#Vol02"
        #expect(store.pageBookmarks(forKey: newKey).map(\.pageIndex) == [3])
        #expect(store.bookRef(forKey: oldKey) == nil)
        #expect(store.bookRef(forKey: newKey)?.path == "/new/Series.zip")
        #expect(store.bookRef(forKey: newKey)?.innerPath == "Vol02")
    }

    private func makeRef(title: String, path: String, innerPath: String? = nil) -> PageBookmarkBookRef {
        PageBookmarkBookRef(
            title: title,
            path: path,
            innerPath: innerPath,
            isDirectory: false,
            bookmarkData: nil
        )
    }

    private func freshStore() -> PageBookmarksStore {
        PageBookmarksStore(defaults: InMemoryKeyValueStore())
    }
}
