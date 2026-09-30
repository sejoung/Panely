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
        let added = pageBookmarks.togglePageBookmark(key: key, pageIndex: currentPageIndex)
        // Keep a way back to this book next to its bookmarks, so the
        // cross-book list can reopen it while another book is on screen.
        if added, let ref = currentBookRef() {
            pageBookmarks.setBookRef(ref, forKey: key)
        }
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

    // MARK: - Removing bookmarks

    func removeCurrentBookPageBookmark(_ bookmark: PageBookmark) {
        guard let key = currentPositionKey else { return }
        pageBookmarks.removePageBookmark(forKey: key, id: bookmark.id)
    }

    func removeAllPageBookmarksInCurrentBook() {
        guard let key = currentPositionKey else { return }
        pageBookmarks.removeAllPageBookmarks(forKey: key)
    }

    // MARK: - Bookmarks in other books

    /// Every bookmarked book other than the one on screen, most recently
    /// bookmarked first.
    var otherBookmarkedBooks: [BookmarkedBook] {
        pageBookmarks.bookmarkedBooks(excluding: currentPositionKey)
    }

    var hasAnyPageBookmarks: Bool {
        !pageBookmarks.pageBookmarksByBook.isEmpty
    }

    /// Open `book` on the bookmarked page. Resolves the book through its saved
    /// security-scoped bookmark (or, for bookmarks that predate it, through
    /// whatever still grants access to that path).
    func openBookmark(_ bookmark: PageBookmark, in book: BookmarkedBook) {
        if book.key == currentPositionKey {
            jumpToBookmark(bookmark)
            return
        }
        guard let target = resolveBookmarkedBook(forKey: book.key) else {
            AppLog.error(.load, "Bookmarked book could not be resolved")
            errorMessage = String(localized: "This bookmarked book can no longer be opened.")
            return
        }
        AppLog.info(
            .load,
            "Bookmark open requested",
            metadata: ["source": "\(DiagnosticRedactor.describe(target.url))"]
        )
        recentItems.record(target.url, title: displayTitle(for: target.url))
        Task {
            await load(
                url: target.url,
                intent: .bookmark(innerPath: target.innerPath, pageIndex: bookmark.pageIndex)
            )
        }
    }

    private func resolveBookmarkedBook(forKey key: String) -> (url: URL, innerPath: String?)? {
        if let ref = pageBookmarks.bookRef(forKey: key) {
            if let data = ref.bookmarkData,
               let result = dependencies.bookmarkResolver.resolveRefreshing(data) {
                let url = result.url.standardizedFileURL
                var updated = ref
                var updatedKey = key
                if let refreshed = result.refreshed {
                    updated.bookmarkData = refreshed.data
                }
                if url.path != ref.path {
                    // The book moved since it was bookmarked: re-file its
                    // bookmarks (and position/progress) under the new path so
                    // they show up once it opens.
                    applyRecentItemMigration(
                        RecentItemPathMigration(oldPath: ref.path, newPath: url.path)
                    )
                    updated.path = url.path
                    updatedKey = PositionKey.replacingSourcePath(in: key, from: ref.path, to: url.path) ?? key
                }
                pageBookmarks.setBookRef(updated, forKey: updatedKey)
                return (url, ref.innerPath)
            }
            return openableURL(forPath: ref.path).map { ($0, ref.innerPath) }
        }

        // No saved reference: the key is the book's path, or `outer#inner`
        // for a volume inside an archive. `#` is legal in filenames, so try
        // the whole key first and then each split point.
        var candidates: [(path: String, innerPath: String?)] = [(key, nil)]
        var searchStart = key.startIndex
        while let hash = key[searchStart...].firstIndex(of: "#") {
            let inner = String(key[key.index(after: hash)...])
            candidates.append((String(key[..<hash]), inner.isEmpty ? nil : inner))
            searchStart = key.index(after: hash)
        }
        for candidate in candidates {
            if let url = openableURL(forPath: candidate.path) {
                return (url, candidate.innerPath)
            }
        }
        return nil
    }

    /// A URL for `path` the sandbox will let us read: already reachable, or
    /// covered by a recent / favorite / remembered-folder grant.
    private func openableURL(forPath path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let item = recentItems.items.first(where: { $0.path == url.path }),
           let resolved = recentItems.resolve(item) {
            return resolved
        }
        if let favorite = favorites.favorites.first(where: { $0.path == url.path }),
           let resolved = favorites.resolve(favorite) {
            return resolved
        }
        // `prepareScope` re-finds this grant and opens the book under it.
        if rememberedFolderGrant(containing: url) != nil { return url }
        return nil
    }

    private func currentBookRef() -> PageBookmarkBookRef? {
        guard let target = currentFavoriteTarget else { return nil }
        let title: String
        if target.innerPath != nil {
            title = "\(displayTitle(for: target.url)) · \(target.title)"
        } else {
            title = target.title
        }
        return PageBookmarkBookRef(
            title: title,
            path: target.url.standardizedFileURL.path,
            innerPath: target.innerPath,
            isDirectory: target.innerPath == nil ? target.isDirectory : isDirectory(target.url),
            bookmarkData: try? dependencies.bookmarkResolver.data(for: target.url)
        )
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
              openedSourceURL != nil,
              // Non-empty relative path: current must be strictly *under* the
              // temp root (an exact match has no inner path).
              let relative = tempRoot.relativeSubpath(to: current),
              !relative.isEmpty else { return nil }
        return relative
    }

}
