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

    private(set) var favorites: [FavoriteBook] = []

    init() {
        load()
    }

    func isFavorite(url: URL) -> Bool {
        favorites.contains { $0.path == url.path }
    }

    /// Adds the book if not already favorited; otherwise removes it.
    func toggleFavorite(url: URL, title: String) {
        if let idx = favorites.firstIndex(where: { $0.path == url.path }) {
            favorites.remove(at: idx)
            save()
            return
        }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let fav = FavoriteBook(
                id: UUID(),
                path: url.path,
                title: title,
                addedAt: Date(),
                bookmarkData: bookmark,
                isDirectory: isDir
            )
            favorites.insert(fav, at: 0)
            save()
        } catch {
            // Bookmark creation failed (e.g., URL not user-accessible). Skip silently
            // — same posture as RecentItemsStore.
        }
    }

    func resolve(_ favorite: FavoriteBook) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: favorite.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        // Refresh the bookmark in place when stale — keeps Favorites usable
        // across file moves without forcing the user to re-add them.
        if isStale, let refreshed = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ), let idx = favorites.firstIndex(where: { $0.id == favorite.id }) {
            favorites[idx].bookmarkData = refreshed
            favorites[idx].path = url.path
            save()
        }
        return url
    }

    func removeFavorite(_ favorite: FavoriteBook) {
        favorites.removeAll { $0.id == favorite.id }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.favoritesKey),
              let decoded = try? JSONDecoder().decode([FavoriteBook].self, from: data)
        else { return }
        favorites = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(data, forKey: Self.favoritesKey)
    }
}
