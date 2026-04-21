import Foundation

@Observable
@MainActor
final class RecentItemsStore {
    private static let defaultsKey = "panely.recentItems"
    private static let maxItems = 10

    private(set) var items: [RecentItem] = []

    init() {
        load()
    }

    func record(_ url: URL, title: String) {
        // Re-opening a recently used item: skip the security-scoped bookmark
        // creation (the most expensive part of this method) and just bump
        // the existing entry to the top. Bookmark data is unchanged.
        if let existingIndex = items.firstIndex(where: { $0.path == url.path }) {
            var existing = items.remove(at: existingIndex)
            existing.openedAt = Date()
            existing.title = title
            items.insert(existing, at: 0)
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

            let item = RecentItem(
                id: UUID(),
                path: url.path,
                title: title,
                openedAt: Date(),
                bookmarkData: bookmark,
                isDirectory: isDir
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
        var isStale = false
        return try? URL(
            resolvingBookmarkData: item.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
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
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
        items = (try? JSONDecoder().decode([RecentItem].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
