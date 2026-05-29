import Foundation

@Observable
@MainActor
final class RecentItemsStore {
    private static let defaultsKey = "panely.recentItems"
    private static let maxItems = 10

    private let bookmarks: any SecurityScopedBookmarking
    private let defaults: any KeyValueStoring
    private(set) var items: [RecentItem] = []

    init(
        bookmarks: any SecurityScopedBookmarking = LiveSecurityScopedBookmarkResolver(),
        defaults: any KeyValueStoring = LiveKeyValueStore()
    ) {
        self.bookmarks = bookmarks
        self.defaults = defaults
        load()
    }

    func record(_ url: URL, title: String) {
        let path = url.standardizedFileURL.path
        if let existingIndex = items.firstIndex(where: { $0.path == path }) {
            var existing = items.remove(at: existingIndex)
            existing.openedAt = Date()
            existing.title = title
            if bookmarks.resolve(existing.bookmarkData)?.isStale == true,
               let refreshed = bookmarks.refreshedData(for: url) {
                existing.bookmarkData = refreshed
            }
            items.insert(existing, at: 0)
            save()
            return
        }

        do {
            let item = RecentItem(
                id: UUID(),
                path: path,
                title: title,
                openedAt: Date(),
                bookmarkData: try bookmarks.data(for: url),
                isDirectory: bookmarks.isDirectory(url)
            )
            items.insert(item, at: 0)

            if items.count > Self.maxItems {
                items = Array(items.prefix(Self.maxItems))
            }

            save()
        } catch {
            // Bookmark creation failed (e.g., URL not user-accessible). Skip silently.
        }
    }

    func resolve(_ item: RecentItem) -> URL? {
        guard let result = bookmarks.resolveRefreshing(item.bookmarkData) else {
            return nil
        }
        if let refreshed = result.refreshed,
           let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].bookmarkData = refreshed.data
            items[idx].path = refreshed.path
            save()
        }
        return result.url
    }

    func remove(_ item: RecentItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func load() {
        items = defaults.loadCodable([RecentItem].self, forKey: Self.defaultsKey) ?? []
    }

    private func save() {
        defaults.saveCodable(items, forKey: Self.defaultsKey)
    }
}
