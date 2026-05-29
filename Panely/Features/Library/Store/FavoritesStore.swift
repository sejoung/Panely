import Foundation

/// Persistent list of books the user has starred. Each entry holds a
/// security-scoped bookmark so the URL stays resolvable after macOS revokes
/// the original Powerbox grant. Mirrors `RecentItemsStore`'s bookmark
/// lifecycle — when resolution returns `isStale`, refresh the bookmark in
/// place rather than forcing the user to re-add the entry.
@Observable
@MainActor
final class FavoritesStore {
    static let favoritesKey = "panely.favoriteBooks"

    private let bookmarks: any SecurityScopedBookmarking
    private let defaults: any KeyValueStoring

    /// In-memory favorites list. Direct assignment is supported so tests
    /// and snapshot fixtures can stage favorites without creating real
    /// security-scoped bookmarks; production code should go through
    /// `toggleFavorite` / `removeFavorite` so persistence stays in sync.
    var favorites: [FavoriteBook] = []

    init(
        bookmarks: any SecurityScopedBookmarking = LiveSecurityScopedBookmarkResolver(),
        defaults: any KeyValueStoring = LiveKeyValueStore()
    ) {
        self.bookmarks = bookmarks
        self.defaults = defaults
        load()
    }

    func isFavorite(url: URL, innerPath: String? = nil) -> Bool {
        let path = url.standardizedFileURL.path
        return favorites.contains { $0.path == path && $0.innerPath == innerPath }
    }

    /// Adds the book if not already favorited; otherwise removes it.
    func toggleFavorite(
        url: URL,
        title: String,
        innerPath: String? = nil,
        isDirectory: Bool? = nil
    ) {
        let path = url.standardizedFileURL.path
        if let idx = favorites.firstIndex(where: { $0.path == path && $0.innerPath == innerPath }) {
            favorites.remove(at: idx)
            save()
            return
        }
        do {
            let fav = FavoriteBook(
                id: UUID(),
                path: path,
                title: title,
                addedAt: Date(),
                bookmarkData: try bookmarks.data(for: url),
                isDirectory: isDirectory ?? bookmarks.isDirectory(url),
                innerPath: innerPath
            )
            favorites.insert(fav, at: 0)
            save()
        } catch {
            // Bookmark creation failed (e.g., URL not user-accessible). Skip silently
            // — same posture as RecentItemsStore.
        }
    }

    func resolve(_ favorite: FavoriteBook) -> URL? {
        guard let result = bookmarks.resolveRefreshing(favorite.bookmarkData) else {
            return nil
        }
        if let refreshed = result.refreshed,
           let idx = favorites.firstIndex(where: { $0.id == favorite.id }) {
            favorites[idx].bookmarkData = refreshed.data
            favorites[idx].path = refreshed.path
            save()
        }
        return result.url
    }

    func removeFavorite(_ favorite: FavoriteBook) {
        favorites.removeAll { $0.id == favorite.id }
        save()
    }

    // MARK: - Persistence

    private func load() {
        if let decoded = defaults.loadCodable([FavoriteBook].self, forKey: Self.favoritesKey) {
            favorites = decoded
        }
    }

    private func save() {
        defaults.saveCodable(favorites, forKey: Self.favoritesKey)
    }
}
