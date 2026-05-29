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
            save()
        }
    }

    // MARK: - Internals

    private func commit(_ list: [PageBookmark], forKey key: String) {
        let sorted = list.sorted { $0.pageIndex < $1.pageIndex }
        if sorted.isEmpty {
            pageBookmarksByBook.removeValue(forKey: key)
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
        guard pageBookmarksByBook.count > Self.maxBookEntries else { return }
        let overflow = pageBookmarksByBook.count - Self.maxBookEntries
        let staleKeys = pageBookmarksByBook
            .map { (key: $0.key, mostRecent: $0.value.map(\.createdAt).max() ?? .distantPast) }
            .sorted { $0.mostRecent < $1.mostRecent }
            .prefix(overflow)
            .map { $0.key }
        for key in staleKeys {
            pageBookmarksByBook.removeValue(forKey: key)
        }
    }

    // MARK: - Persistence

    private func load() {
        if let decoded = defaults.loadCodable([String: [PageBookmark]].self, forKey: Self.pageBookmarksKey) {
            pageBookmarksByBook = decoded
        }
    }

    private func save() {
        defaults.saveCodable(pageBookmarksByBook, forKey: Self.pageBookmarksKey)
    }
}
