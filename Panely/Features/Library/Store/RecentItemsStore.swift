import Foundation

nonisolated enum RecentItemAvailability: Equatable, Sendable {
    case unknown
    case available(URL)
    /// The bookmark still resolves, but its resource is not currently
    /// reachable. Keep the item so removable/network volumes can recover.
    case temporarilyUnavailable
    case invalidBookmark
}

nonisolated struct RecentItemPathMigration: Equatable, Sendable {
    let oldPath: String
    let newPath: String
}

nonisolated struct RecentItemRefreshResult: Equatable, Sendable {
    let availability: RecentItemAvailability
    let migration: RecentItemPathMigration?
}

@Observable
@MainActor
final class RecentItemsStore {
    private static let defaultsKey = "panely.recentItems"
    /// Keep more bookmark-backed sources for Continue Reading than the File
    /// menu renders. This avoids losing an unfinished book merely because ten
    /// unrelated files were opened, without turning Open Recent into a wall of
    /// entries.
    private static let maxItems = 50
    private static let maxMenuItems = 10

    private let bookmarks: any SecurityScopedBookmarking
    private let defaults: any KeyValueStoring
    private(set) var items: [RecentItem] = []
    private(set) var availabilityByID: [UUID: RecentItemAvailability] = [:]

    var menuItems: [RecentItem] {
        Array(items.prefix(Self.maxMenuItems))
    }

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
            availabilityByID[existing.id] = .available(url.standardizedFileURL)
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
            availabilityByID[item.id] = .available(url.standardizedFileURL)

            if items.count > Self.maxItems {
                let retained = Array(items.prefix(Self.maxItems))
                let retainedIDs = Set(retained.map(\.id))
                items = retained
                availabilityByID = availabilityByID.filter { retainedIDs.contains($0.key) }
            }

            save()
        } catch {
            // Bookmark creation failed (e.g., URL not user-accessible). Skip silently.
        }
    }

    func resolve(_ item: RecentItem) -> URL? {
        guard let result = bookmarks.resolveRefreshing(item.bookmarkData) else {
            availabilityByID[item.id] = .invalidBookmark
            return nil
        }
        let url = result.url.standardizedFileURL
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            var changed = false
            if items[idx].path != url.path {
                items[idx].path = url.path
                changed = true
            }
            if let refreshed = result.refreshed {
                items[idx].bookmarkData = refreshed.data
                changed = true
            }
            if changed { save() }
        }
        availabilityByID[item.id] = .available(url)
        return url
    }

    func availability(for item: RecentItem) -> RecentItemAvailability {
        availabilityByID[item.id] ?? .unknown
    }

    func availableURL(for item: RecentItem) -> URL? {
        guard case .available(let url) = availability(for: item) else { return nil }
        return url
    }

    /// Re-resolve every persisted bookmark away from SwiftUI's render path.
    /// Unreachable items stay stored but are omitted from Continue Reading.
    func refreshAvailability() async -> [RecentItemPathMigration] {
        let snapshot = items
        let checks = await withTaskGroup(
            of: (UUID, BookmarkAvailabilityCheck).self,
            returning: [(UUID, BookmarkAvailabilityCheck)].self
        ) { group in
            for item in snapshot {
                let bookmarks = self.bookmarks
                group.addTask {
                    (item.id, Self.checkAvailability(of: item, bookmarks: bookmarks))
                }
            }
            var results: [(UUID, BookmarkAvailabilityCheck)] = []
            for await result in group { results.append(result) }
            return results
        }

        var migrations: [RecentItemPathMigration] = []
        for (id, check) in checks {
            guard let item = items.first(where: { $0.id == id }) else { continue }
            let result = apply(check, to: item)
            if let migration = result.migration { migrations.append(migration) }
        }
        return migrations
    }

    /// Revalidate one item immediately before opening it. This closes the race
    /// where a file is deleted after the last app-activation refresh.
    func refreshAvailability(for item: RecentItem) async -> RecentItemRefreshResult {
        let bookmarks = self.bookmarks
        let check = await Task.detached(priority: .userInitiated) {
            Self.checkAvailability(of: item, bookmarks: bookmarks)
        }.value
        guard let current = items.first(where: { $0.id == item.id }) else {
            return RecentItemRefreshResult(availability: .invalidBookmark, migration: nil)
        }
        return apply(check, to: current)
    }

    func remove(_ item: RecentItem) {
        items.removeAll { $0.id == item.id }
        availabilityByID.removeValue(forKey: item.id)
        save()
    }

    func clear() {
        items = []
        availabilityByID = [:]
        save()
    }

    private func load() {
        items = defaults.loadCodable([RecentItem].self, forKey: Self.defaultsKey) ?? []
        availabilityByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, .unknown) })
    }

    private func save() {
        defaults.saveCodable(items, forKey: Self.defaultsKey)
    }

    private nonisolated enum BookmarkAvailabilityCheck: Sendable {
        case available(url: URL, refreshedData: Data?)
        case temporarilyUnavailable
        case invalidBookmark
    }

    private nonisolated static func checkAvailability(
        of item: RecentItem,
        bookmarks: any SecurityScopedBookmarking
    ) -> BookmarkAvailabilityCheck {
        guard let result = bookmarks.resolveRefreshing(item.bookmarkData) else {
            return .invalidBookmark
        }
        let url = result.url.standardizedFileURL
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.checkResourceIsReachable()) == true else {
            return .temporarilyUnavailable
        }
        return .available(url: url, refreshedData: result.refreshed?.data)
    }

    private func apply(
        _ check: BookmarkAvailabilityCheck,
        to item: RecentItem
    ) -> RecentItemRefreshResult {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            return RecentItemRefreshResult(availability: .invalidBookmark, migration: nil)
        }

        switch check {
        case .invalidBookmark:
            availabilityByID[item.id] = .invalidBookmark
            return RecentItemRefreshResult(availability: .invalidBookmark, migration: nil)
        case .temporarilyUnavailable:
            availabilityByID[item.id] = .temporarilyUnavailable
            return RecentItemRefreshResult(availability: .temporarilyUnavailable, migration: nil)
        case .available(let url, let refreshedData):
            let oldPath = items[index].path
            let newPath = url.standardizedFileURL.path
            var changed = false
            if oldPath != newPath {
                items[index].path = newPath
                changed = true
            }
            if let refreshedData {
                items[index].bookmarkData = refreshedData
                changed = true
            }
            if changed { save() }
            let availability = RecentItemAvailability.available(url.standardizedFileURL)
            availabilityByID[item.id] = availability
            let migration = oldPath == newPath
                ? nil
                : RecentItemPathMigration(oldPath: oldPath, newPath: newPath)
            return RecentItemRefreshResult(availability: availability, migration: migration)
        }
    }
}
