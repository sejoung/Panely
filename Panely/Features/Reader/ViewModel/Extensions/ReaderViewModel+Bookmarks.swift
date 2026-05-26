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
        guard let target = currentFavoriteTarget else { return false }
        return favorites.isFavorite(url: target.url, innerPath: target.innerPath)
    }

    func toggleFavoriteForCurrentBook() {
        guard let target = currentFavoriteTarget else { return }
        favorites.toggleFavorite(
            url: target.url,
            title: target.title,
            innerPath: target.innerPath,
            isDirectory: target.isDirectory
        )
    }

    /// Open a favorite book, resolving its security-scoped bookmark the same
    /// way recent items do.
    func openFavorite(_ favorite: FavoriteBook) {
        guard let url = favorites.resolve(favorite) else { return }
        recentItems.record(url, title: displayTitle(for: url))
        Task { await load(url: url, intent: .favorite(innerPath: favorite.innerPath)) }
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

    // MARK: - Favorite identity

    private struct FavoriteTarget {
        let url: URL
        let title: String
        let innerPath: String?
        let isDirectory: Bool
    }

    /// For zip-in-zip volumes, `currentSourceURL` points into a temp/cache
    /// extraction. Persist the user-granted outer archive bookmark plus the
    /// inner relative path instead, so favorites survive cleanup and cache
    /// eviction.
    private var currentFavoriteTarget: FavoriteTarget? {
        guard let current = currentSourceURL else { return nil }

        if let innerPath = currentInnerArchiveRelativePath,
           let opened = openedSourceURL {
            return FavoriteTarget(
                url: opened,
                title: displayTitle(for: current),
                innerPath: innerPath,
                isDirectory: isDirectory(current)
            )
        }

        return FavoriteTarget(
            url: current,
            title: displayTitle(for: current),
            innerPath: nil,
            isDirectory: isDirectory(current)
        )
    }

    private var currentInnerArchiveRelativePath: String? {
        guard tempDir.isActive,
              let tempRoot = tempDir.url,
              let current = currentSourceURL,
              tempRoot.isAncestor(of: current),
              openedSourceURL != nil else { return nil }

        let rootPath = tempRoot.standardizedFileURL.path
        let currentPath = current.standardizedFileURL.path
        guard currentPath != rootPath,
              currentPath.hasPrefix(rootPath + "/") else { return nil }
        return String(currentPath.dropFirst(rootPath.count + 1))
    }

}
