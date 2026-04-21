import Testing
import Foundation
@testable import Panely

/// `BookmarksStore` reads/writes `UserDefaults.standard`, so the suite is
/// serialised to avoid tests clobbering each other's state through the
/// shared defaults.
@MainActor
@Suite(.serialized)
struct BookmarksStoreTests {

    // MARK: Page bookmarks — pure logic

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

    // MARK: Page bookmarks — persistence

    @Test func pageBookmarksPersistAcrossStoreInstances() {
        let key = "book-\(UUID().uuidString)"
        let writer = freshStore()
        _ = writer.togglePageBookmark(key: key, pageIndex: 42)

        // A brand-new store must read what the previous one wrote through
        // UserDefaults — proves the load/save symmetry.
        let reader = BookmarksStore()
        #expect(reader.isPageBookmarked(key: key, pageIndex: 42) == true)
    }

    // MARK: Favorites — round-trip on real file

    @Test func toggleFavoriteAddsRealFileThenRemoves() throws {
        let store = freshStore()
        let tempDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("book.cbz")
        _ = try Fixture.writeFile(fileURL)

        #expect(store.isFavorite(url: fileURL) == false)

        store.toggleFavorite(url: fileURL, title: "book")
        #expect(store.isFavorite(url: fileURL) == true)
        #expect(store.favorites.contains { $0.path == fileURL.path })

        store.toggleFavorite(url: fileURL, title: "book")
        #expect(store.isFavorite(url: fileURL) == false)
    }

    @Test func resolveReturnsEquivalentURL() throws {
        let store = freshStore()
        let tempDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("book.cbz")
        _ = try Fixture.writeFile(fileURL)

        store.toggleFavorite(url: fileURL, title: "book")
        guard let fav = store.favorites.first(where: { $0.path == fileURL.path }) else {
            Issue.record("expected favorite for just-added URL")
            return
        }

        let resolved = store.resolve(fav)
        // Compare after resolving symlinks because bookmark resolution may
        // canonicalise `/var/...` to `/private/var/...` on macOS.
        #expect(
            resolved?.resolvingSymlinksInPath().path
                == fileURL.resolvingSymlinksInPath().path
        )
    }

    @Test func removeFavoriteDropsTheEntry() throws {
        let store = freshStore()
        let tempDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("book.cbz")
        _ = try Fixture.writeFile(fileURL)

        store.toggleFavorite(url: fileURL, title: "book")
        guard let fav = store.favorites.first(where: { $0.path == fileURL.path }) else {
            Issue.record("expected favorite entry")
            return
        }

        store.removeFavorite(fav)
        #expect(store.isFavorite(url: fileURL) == false)
    }

    // MARK: helpers

    private func freshStore() -> BookmarksStore {
        // Clear both persisted slots so each test starts from a known empty
        // state. Suite-level serialisation prevents a concurrent sibling
        // from reading an empty store mid-write.
        UserDefaults.standard.removeObject(forKey: "panely.favoriteBooks")
        UserDefaults.standard.removeObject(forKey: "panely.pageBookmarks")
        return BookmarksStore()
    }
}
