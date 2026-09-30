import Foundation

/// Per-book page bookmarks keyed by the stable `PositionKey` so bookmarks
/// survive archive re-extraction. Capped on two axes so unbounded reader
/// history can't bloat `UserDefaults` indefinitely — the per-book cap drops
/// the oldest bookmark inside a book, the total-books cap drops the least-
/// recently-touched book entirely.
@Observable
@MainActor
final class PageBookmarksStore {
    static let pageBookmarksKey = "panely.pageBookmarks"
    static let bookRefsKey = "panely.pageBookmarkBooks"
    private let defaults: any KeyValueStoring

    /// Per-book bookmark cap. Picked so that even a maxed-out book stays
    /// well under the UserDefaults practical limit when multiplied across
    /// many books (500 entries × ~80 bytes ≈ 40 KB per book).
    static let maxBookmarksPerBook = 500
    /// Total book entries cap. Above this we drop the least-recently-touched
    /// book's bookmarks on the next write. Prevents unbounded growth from a
    /// long history of opened-then-deleted books.
    static let maxBookEntries = 200

    /// Keyed by `PositionKey`. Values are kept sorted by `pageIndex` on
    /// write. Direct assignment is supported so tests and snapshot fixtures
    /// can stage bookmark sets without driving the toggle path; production
    /// code should go through `togglePageBookmark` / `removePageBookmark`
    /// so persistence + caps stay in sync.
    var pageBookmarksByBook: [String: [PageBookmark]] = [:]

    /// How to reopen each bookmarked book, keyed like `pageBookmarksByBook`.
    /// Optional per book: bookmarks saved before the cross-book list existed
    /// have no entry and fall back to their key (a path) for title and lookup.
    private(set) var bookRefs: [String: PageBookmarkBookRef] = [:]

    init(defaults: any KeyValueStoring = LiveKeyValueStore()) {
        self.defaults = defaults
        load()
    }

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
            commit(list, forKey: key)
            return false
        }
        // Cap per-book bookmarks. Drop the oldest entry to make room — keeps
        // recent intent intact while preventing pathological growth.
        if list.count >= Self.maxBookmarksPerBook {
            list.sort { $0.createdAt < $1.createdAt }
            list.removeFirst()
        }
        list.append(PageBookmark(pageIndex: pageIndex))
        commit(list, forKey: key)
        return true
    }

    func removePageBookmark(forKey key: String, id: UUID) {
        var list = pageBookmarksByBook[key] ?? []
        list.removeAll { $0.id == id }
        commit(list, forKey: key)
    }

    /// Drop every bookmark in one book.
    func removeAllPageBookmarks(forKey key: String) {
        guard pageBookmarksByBook[key] != nil else { return }
        commit([], forKey: key)
    }

    /// Drop every bookmark in every book.
    func removeAll() {
        guard !pageBookmarksByBook.isEmpty || !bookRefs.isEmpty else { return }
        pageBookmarksByBook = [:]
        bookRefs = [:]
        save()
    }

    var totalBookmarkCount: Int {
        pageBookmarksByBook.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Cross-book listing

    /// Remember how to reopen the book behind `key`. Ignored for a book with
    /// no bookmarks, so a ref can't outlive the list it describes.
    func setBookRef(_ ref: PageBookmarkBookRef, forKey key: String) {
        guard pageBookmarksByBook[key] != nil, bookRefs[key] != ref else { return }
        bookRefs[key] = ref
        save()
    }

    func bookRef(forKey key: String) -> PageBookmarkBookRef? {
        bookRefs[key]
    }

    /// Display title for a bookmarked book: the saved one, or derived from the
    /// key (`/path/Series.cbz#Vol02` → "Series · Vol02") for older bookmarks.
    func title(forKey key: String) -> String {
        if let title = bookRefs[key]?.title, !title.isEmpty { return title }
        return Self.derivedTitle(forKey: key)
    }

    /// Name of the folder holding the bookmarked book (the outer archive's
    /// folder for zip-in-zip).
    func folderName(forKey key: String) -> String {
        let path = bookRefs[key]?.path
            ?? String(key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        // Only a real path has a folder; anything else would be resolved
        // against the working directory and name that instead.
        guard path.hasPrefix("/") else { return "" }
        return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }

    static func derivedTitle(forKey key: String) -> String {
        let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let outer = URL(fileURLWithPath: String(parts[0])).deletingPathExtension().lastPathComponent
        guard parts.count == 2, !parts[1].isEmpty else { return outer }
        let inner = URL(fileURLWithPath: String(parts[1])).deletingPathExtension().lastPathComponent
        return "\(outer) · \(inner)"
    }

    /// Every bookmarked book except `excludedKey`, most recently bookmarked
    /// first — the order someone looking for "that page I marked" expects.
    func bookmarkedBooks(excluding excludedKey: String? = nil) -> [BookmarkedBook] {
        var dated: [(book: BookmarkedBook, latest: Date)] = []
        for (key, bookmarks) in pageBookmarksByBook where key != excludedKey && !bookmarks.isEmpty {
            let book = BookmarkedBook(
                key: key,
                title: title(forKey: key),
                folderName: folderName(forKey: key),
                bookmarks: bookmarks
            )
            dated.append((book, bookmarks.map(\.createdAt).max() ?? .distantPast))
        }
        dated.sort { lhs, rhs in
            lhs.latest != rhs.latest ? lhs.latest > rhs.latest : lhs.book.key < rhs.book.key
        }
        return dated.map(\.book)
    }

    /// Move a book's bookmarks under a new key, merging with whatever is
    /// already there. Used when a saved book resolves to a different path
    /// than the one its bookmarks were filed under.
    func moveBookmarks(fromKey oldKey: String, toKey newKey: String) {
        guard oldKey != newKey, let moving = pageBookmarksByBook[oldKey] else { return }
        let combined = (pageBookmarksByBook[newKey] ?? []) + moving
        pageBookmarksByBook.removeValue(forKey: oldKey)
        pageBookmarksByBook[newKey] = Self.deduplicated(combined)
        if let ref = bookRefs.removeValue(forKey: oldKey), bookRefs[newKey] == nil {
            bookRefs[newKey] = ref
        }
        save()
    }

    /// First bookmark whose `pageIndex > from`. Nil if none.
    func nextBookmark(forKey key: String, after from: Int) -> PageBookmark? {
        pageBookmarks(forKey: key).first { $0.pageIndex > from }
    }

    /// Last bookmark whose `pageIndex < from`. Nil if none.
    func previousBookmark(forKey key: String, before from: Int) -> PageBookmark? {
        pageBookmarks(forKey: key).last { $0.pageIndex < from }
    }

    /// Drop bookmark entries whose books are no longer reachable via
    /// `liveKeys`. Call from the viewer after a successful load so that
    /// long-deleted books don't accumulate forever. `liveKeys` should
    /// include every `PositionKey` that's still resolvable (favorites,
    /// recents, current book). Passing an empty set is a no-op for safety.
    func pruneOrphaned(keeping liveKeys: Set<String>) {
        guard !liveKeys.isEmpty else { return }
        let before = pageBookmarksByBook.count
        pageBookmarksByBook = pageBookmarksByBook.filter { liveKeys.contains($0.key) }
        if pageBookmarksByBook.count != before {
            dropOrphanedBookRefs()
            save()
        }
    }

    func migrateSourcePath(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        var migrated = pageBookmarksByBook
        var changed = false

        for (key, bookmarks) in pageBookmarksByBook {
            guard let newKey = PositionKey.replacingSourcePath(
                in: key,
                from: oldPath,
                to: newPath
            ) else { continue }
            migrated.removeValue(forKey: key)
            let combined = (migrated[newKey] ?? []) + bookmarks
            migrated[newKey] = Self.deduplicated(combined)
            if var ref = bookRefs.removeValue(forKey: key) {
                if ref.path == oldPath { ref.path = newPath }
                bookRefs[newKey] = ref
            }
            changed = true
        }
        guard changed else { return }
        pageBookmarksByBook = migrated
        save()
    }

    // MARK: - Internals

    private func commit(_ list: [PageBookmark], forKey key: String) {
        let sorted = list.sorted { $0.pageIndex < $1.pageIndex }
        if sorted.isEmpty {
            pageBookmarksByBook.removeValue(forKey: key)
            bookRefs.removeValue(forKey: key)
        } else {
            pageBookmarksByBook[key] = sorted
        }
        pruneToBookEntryCap()
        save()
    }

    /// Cap the number of distinct books tracked. When over the limit, drop the
    /// entries whose most-recent bookmark is oldest — i.e. the least recently
    /// touched books.
    private func pruneToBookEntryCap() {
        pageBookmarksByBook.capByRecency(to: Self.maxBookEntries) {
            $0.map(\.createdAt).max() ?? .distantPast
        }
        dropOrphanedBookRefs()
    }

    private func dropOrphanedBookRefs() {
        guard bookRefs.contains(where: { pageBookmarksByBook[$0.key] == nil }) else { return }
        bookRefs = bookRefs.filter { pageBookmarksByBook[$0.key] != nil }
    }

    /// One entry per bookmark id and per page, sorted by page.
    private static func deduplicated(_ bookmarks: [PageBookmark]) -> [PageBookmark] {
        var seenIDs = Set<UUID>()
        var seenPages = Set<Int>()
        return bookmarks
            .filter { seenIDs.insert($0.id).inserted && seenPages.insert($0.pageIndex).inserted }
            .sorted { $0.pageIndex < $1.pageIndex }
    }

    // MARK: - Persistence

    private func load() {
        if let decoded = defaults.loadCodable([String: [PageBookmark]].self, forKey: Self.pageBookmarksKey) {
            pageBookmarksByBook = decoded
        }
        if let decoded = defaults.loadCodable([String: PageBookmarkBookRef].self, forKey: Self.bookRefsKey) {
            bookRefs = decoded.filter { pageBookmarksByBook[$0.key] != nil }
        }
    }

    private func save() {
        defaults.saveCodable(pageBookmarksByBook, forKey: Self.pageBookmarksKey)
        defaults.saveCodable(bookRefs, forKey: Self.bookRefsKey)
    }
}
