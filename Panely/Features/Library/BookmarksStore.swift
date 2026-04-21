import Foundation

/// Persistent store for user-created bookmarks. Two concerns live here so
/// they share a single JSON-encoded `UserDefaults` session:
///
/// - **Favorite books** — security-scoped bookmarks to book URLs the user
///   has starred, mirroring `RecentItemsStore`'s bookmark lifecycle.
/// - **Page bookmarks** — per-book page indices keyed by the stable
///   `PositionKey` so they survive archive re-extraction.
@Observable
@MainActor
final class BookmarksStore {
    private static let favoritesKey = "panely.favoriteBooks"
    private static let pageBookmarksKey = "panely.pageBookmarks"

    private(set) var favorites: [FavoriteBook] = []
    /// Keyed by `PositionKey`. Values are kept sorted by `pageIndex` on write.
    private(set) var pageBookmarksByBook: [String: [PageBookmark]] = [:]

    init() {
        load()
    }

    // MARK: Favorite books

    func isFavorite(url: URL) -> Bool {
        favorites.contains { $0.path == url.path }
    }

    /// Adds the book if not already favorited; otherwise removes it.
    func toggleFavorite(url: URL, title: String) {
        if let idx = favorites.firstIndex(where: { $0.path == url.path }) {
            favorites.remove(at: idx)
            saveFavorites()
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
            saveFavorites()
        } catch {
            // Bookmark creation failed (e.g., URL not user-accessible). Skip silently
            // — same posture as RecentItemsStore.
        }
    }

    func resolve(_ favorite: FavoriteBook) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: favorite.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    func removeFavorite(_ favorite: FavoriteBook) {
        favorites.removeAll { $0.id == favorite.id }
        saveFavorites()
    }

    // MARK: Page bookmarks

    func pageBookmarks(forKey key: String) -> [PageBookmark] {
        pageBookmarksByBook[key] ?? []
    }

    func isPageBookmarked(key: String, pageIndex: Int) -> Bool {
        pageBookmarks(forKey: key).contains { $0.pageIndex == pageIndex }
    }

    /// Adds or removes a bookmark at the given page. Returns true if the
    /// bookmark now exists, false if it was removed.
    @discardableResult
    func togglePageBookmark(key: String, pageIndex: Int) -> Bool {
        var list = pageBookmarksByBook[key] ?? []
        if let idx = list.firstIndex(where: { $0.pageIndex == pageIndex }) {
            list.remove(at: idx)
            commitPageBookmarks(list, forKey: key)
            return false
        }
        list.append(PageBookmark(pageIndex: pageIndex))
        commitPageBookmarks(list, forKey: key)
        return true
    }

    func removePageBookmark(forKey key: String, id: UUID) {
        var list = pageBookmarksByBook[key] ?? []
        list.removeAll { $0.id == id }
        commitPageBookmarks(list, forKey: key)
    }

    /// First bookmark whose `pageIndex > from`. Nil if none.
    func nextBookmark(forKey key: String, after from: Int) -> PageBookmark? {
        pageBookmarks(forKey: key).first { $0.pageIndex > from }
    }

    /// Last bookmark whose `pageIndex < from`. Nil if none.
    func previousBookmark(forKey key: String, before from: Int) -> PageBookmark? {
        pageBookmarks(forKey: key).last { $0.pageIndex < from }
    }

    private func commitPageBookmarks(_ list: [PageBookmark], forKey key: String) {
        let sorted = list.sorted { $0.pageIndex < $1.pageIndex }
        if sorted.isEmpty {
            pageBookmarksByBook.removeValue(forKey: key)
        } else {
            pageBookmarksByBook[key] = sorted
        }
        savePageBookmarks()
    }

    // MARK: Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.favoritesKey),
           let decoded = try? JSONDecoder().decode([FavoriteBook].self, from: data) {
            favorites = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.pageBookmarksKey),
           let decoded = try? JSONDecoder().decode([String: [PageBookmark]].self, from: data) {
            pageBookmarksByBook = decoded
        }
    }

    private func saveFavorites() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(data, forKey: Self.favoritesKey)
    }

    private func savePageBookmarks() {
        guard let data = try? JSONEncoder().encode(pageBookmarksByBook) else { return }
        UserDefaults.standard.set(data, forKey: Self.pageBookmarksKey)
    }
}
