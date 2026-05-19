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
        // the existing entry to the top. If the existing bookmark is stale,
        // refresh it now — that's the whole reason we kept the URL around.
        if let existingIndex = items.firstIndex(where: { $0.path == url.path }) {
            var existing = items.remove(at: existingIndex)
            existing.openedAt = Date()
            existing.title = title
            var isStale = false
            if (try? URL(
                resolvingBookmarkData: existing.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )) != nil, isStale,
               let refreshed = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
               ) {
                existing.bookmarkData = refreshed
            }
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
        guard let url = try? URL(
            resolvingBookmarkData: item.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        // If macOS marked the bookmark stale (file moved/renamed but still
        // resolvable), regenerate it now so the next launch doesn't pay the
        // resolution cost or risk failure as the staleness compounds.
        if isStale, let refreshed = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ), let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].bookmarkData = refreshed
            items[idx].path = url.path
            save()
        }
        return url
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
