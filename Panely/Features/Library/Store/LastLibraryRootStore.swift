import Foundation

/// Persists a security-scoped bookmark to the last library root the user
/// browsed, so the sidebar can reopen that folder on the next launch instead
/// of starting empty (and making the user pick a folder every session).
///
/// One bookmark, not a list — it mirrors how `RecentItemsStore` /
/// `FavoritesStore` persist folder access across launches, just for the single
/// "current library" slot.
@MainActor
final class LastLibraryRootStore {
    nonisolated static let defaultsKey = "panely.lastLibraryRoot"

    private let bookmarks: any SecurityScopedBookmarking
    private let defaults: any KeyValueStoring
    private let key: String

    init(
        bookmarks: any SecurityScopedBookmarking = LiveSecurityScopedBookmarkResolver(),
        defaults: any KeyValueStoring = LiveKeyValueStore(),
        key: String = LastLibraryRootStore.defaultsKey
    ) {
        self.bookmarks = bookmarks
        self.defaults = defaults
        self.key = key
    }

    /// Persist `url` as the root to restore next launch. Silently no-ops when a
    /// bookmark can't be minted (e.g. a URL the user never granted access to).
    func save(_ url: URL) {
        guard let data = try? bookmarks.data(for: url) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    /// Resolve the persisted root, refreshing a stale bookmark in place. Returns
    /// the URL — the caller starts its security scope — or `nil` when nothing is
    /// stored / it can no longer be resolved (folder deleted, drive ejected).
    func restore() -> URL? {
        guard let data = defaults.data(forKey: key),
              let result = bookmarks.resolveRefreshing(data) else { return nil }
        if let refreshed = result.refreshed {
            defaults.set(refreshed.data, forKey: key)
        }
        return result.url
    }
}
