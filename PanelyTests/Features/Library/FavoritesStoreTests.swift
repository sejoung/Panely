import Testing
import Foundation
@testable import Panely

/// `FavoritesStore` reads/writes `UserDefaults.standard`, so the suite is
/// serialised to avoid tests clobbering each other's state through the
/// shared defaults.
@MainActor
@Suite(.serialized)
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

    private func freshStore() -> FavoritesStore {
        UserDefaults.standard.removeObject(forKey: FavoritesStore.favoritesKey)
        return FavoritesStore()
    }
}
