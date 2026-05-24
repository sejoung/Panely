import Testing
import Foundation
@testable import Panely

@MainActor
struct FavoritesStoreTests {

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

    @Test func innerPathDistinguishesFavoritesInsideSameArchive() throws {
        let store = freshStore()
        let tempDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("series.cbz")
        _ = try Fixture.writeFile(fileURL)

        store.toggleFavorite(url: fileURL, title: "Vol01", innerPath: "Vol01")
        store.toggleFavorite(url: fileURL, title: "Vol02", innerPath: "Vol02")

        #expect(store.favorites.count == 2)
        #expect(store.isFavorite(url: fileURL, innerPath: "Vol01"))
        #expect(store.isFavorite(url: fileURL, innerPath: "Vol02"))
        #expect(store.isFavorite(url: fileURL, innerPath: nil) == false)

        store.toggleFavorite(url: fileURL, title: "Vol01", innerPath: "Vol01")
        #expect(store.isFavorite(url: fileURL, innerPath: "Vol01") == false)
        #expect(store.isFavorite(url: fileURL, innerPath: "Vol02"))
    }

    @Test func toggleFavoriteUsesInjectedBookmarkResolver() {
        let store = freshStore(bookmarks: FakeBookmarkResolver())
        let url = URL(fileURLWithPath: "/fake/book.cbz")

        store.toggleFavorite(url: url, title: "book")

        #expect(store.favorites.first?.bookmarkData == Data([0xBA, 0xAD]))
        #expect(store.favorites.first?.isDirectory == true)
    }

    private func freshStore(
        bookmarks: any SecurityScopedBookmarking = LiveSecurityScopedBookmarkResolver()
    ) -> FavoritesStore {
        FavoritesStore(bookmarks: bookmarks, defaults: InMemoryKeyValueStore())
    }
}

private nonisolated struct FakeBookmarkResolver: SecurityScopedBookmarking {
    func data(for url: URL) throws -> Data {
        Data([0xBA, 0xAD])
    }

    func resolve(_ bookmarkData: Data) -> SecurityScopedBookmark.Resolution? {
        SecurityScopedBookmark.Resolution(url: URL(fileURLWithPath: "/fake/book.cbz"), isStale: false)
    }

    func refreshedData(for url: URL) -> Data? {
        Data([0xF0, 0x0D])
    }

    func isDirectory(_ url: URL) -> Bool {
        true
    }
}
