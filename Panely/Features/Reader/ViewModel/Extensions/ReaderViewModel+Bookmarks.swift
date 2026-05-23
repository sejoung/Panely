import Foundation

/// Integration between `ReaderViewModel` and the two bookmark stores —
/// `FavoritesStore` (starred books) and `PageBookmarksStore` (per-book
/// pages keyed by the stable `PositionKey`). All methods are no-ops when
/// no source is loaded.
extension ReaderViewModel {

    // MARK: - Position key for the active book

    /// Stable key for the current book. Nil when no source is open.
    var currentPositionKey: String? {
        guard let url = currentSourceURL else { return nil }
        return positionKey(for: url)
    }

    // MARK: - Favorite book toggle

    var isCurrentBookFavorite: Bool {
        guard let url = currentSourceURL else { return false }
        return favorites.isFavorite(url: url)
    }

    func toggleFavoriteForCurrentBook() {
        guard let url = currentSourceURL else { return }
        favorites.toggleFavorite(url: url, title: displayTitle(for: url))
    }

    /// Open a favorite book, resolving its security-scoped bookmark the same
    /// way recent items do.
    func openFavorite(_ favorite: FavoriteBook) {
        guard let url = favorites.resolve(favorite) else { return }
        recentItems.record(url, title: displayTitle(for: url))
        Task { await load(url: url) }
    }

    // MARK: - Page bookmark toggle + queries

    var isCurrentPageBookmarked: Bool {
        guard let key = currentPositionKey else { return false }
        return pageBookmarks.isPageBookmarked(key: key, pageIndex: currentPageIndex)
    }

    func toggleCurrentPageBookmark() {
        guard let key = currentPositionKey else { return }
        pageBookmarks.togglePageBookmark(key: key, pageIndex: currentPageIndex)
    }

    var currentBookPageBookmarks: [PageBookmark] {
        guard let key = currentPositionKey else { return [] }
        return pageBookmarks.pageBookmarks(forKey: key)
    }

    var hasPageBookmarks: Bool {
        !currentBookPageBookmarks.isEmpty
    }

    // MARK: - Page bookmark navigation

    var canGoNextBookmark: Bool {
        guard let key = currentPositionKey else { return false }
        return pageBookmarks.nextBookmark(forKey: key, after: currentPageIndex) != nil
    }

    var canGoPreviousBookmark: Bool {
        guard let key = currentPositionKey else { return false }
        return pageBookmarks.previousBookmark(forKey: key, before: currentPageIndex) != nil
    }

    func jumpToNextBookmark() {
        guard let key = currentPositionKey,
              let bm = pageBookmarks.nextBookmark(forKey: key, after: currentPageIndex) else { return }
        jump(to: bm.pageIndex)
    }

    func jumpToPreviousBookmark() {
        guard let key = currentPositionKey,
              let bm = pageBookmarks.previousBookmark(forKey: key, before: currentPageIndex) else { return }
        jump(to: bm.pageIndex)
    }

    func jumpToBookmark(_ bookmark: PageBookmark) {
        jump(to: bookmark.pageIndex)
    }
}
