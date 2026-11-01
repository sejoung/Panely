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
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    private(set) var items: [RecentItem] = [] {
        didSet { revision &+= 1 }
    }
    private(set) var availabilityByID: [UUID: RecentItemAvailability] = [:] {
        didSet { revision &+= 1 }
    }
    /// Bumped whenever `items` or their availability change (see
    /// `ReadingProgressStore.revision`).
    private(set) var revision = 0

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

    /// The file-system half of recording a book: minting a security-scoped
    /// bookmark (or probing an existing one for staleness) and checking its
    /// kind. No store state, so it can run off the main thread.
    private nonisolated struct RecordProbe: Sendable {
        var refreshedBookmark: Data?
        var newBookmark: Data?
        var isDirectory = false
    }

    private nonisolated static func probe(
        url: URL,
        existingBookmark: Data?,
        bookmarks: any SecurityScopedBookmarking
    ) -> RecordProbe {
        if let existingBookmark {
            // Only a staleness probe — `url` is already open — so never mount.
            guard bookmarks.resolve(existingBookmark, allowingMount: false)?.isStale == true else {
                return RecordProbe()
            }
            return RecordProbe(refreshedBookmark: bookmarks.refreshedData(for: url))
        }
        // Bookmark creation can fail (e.g., URL not user-accessible). Skip silently.
        guard let data = try? bookmarks.data(for: url) else { return RecordProbe() }
        return RecordProbe(newBookmark: data, isDirectory: bookmarks.isDirectory(url))
    }

    func record(_ url: URL, title: String) {
        let path = url.standardizedFileURL.path
        let existing = items.first(where: { $0.path == path })?.bookmarkData
        apply(
            Self.probe(url: url, existingBookmark: existing, bookmarks: bookmarks),
            url: url,
            title: title
        )
    }

    /// `record` for the open paths: the bookmark work happens off the main
    /// thread (a network volume makes it slow), and each request waits for the
    /// one before it so recency order still follows the order books were
    /// opened in. Awaiting `recordingSettled()` waits for them all.
    func recordInBackground(_ url: URL, title: String) {
        let previous = recordingTask
        let bookmarks = bookmarks
        recordingTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let path = url.standardizedFileURL.path
            let existing = self.items.first(where: { $0.path == path })?.bookmarkData
            let probe = await Task.detached(priority: .userInitiated) {
                Self.probe(url: url, existingBookmark: existing, bookmarks: bookmarks)
            }.value
            self.apply(probe, url: url, title: title)
        }
    }

    func recordingSettled() async {
        await recordingTask?.value
    }

    private func apply(_ probe: RecordProbe, url: URL, title: String) {
        let path = url.standardizedFileURL.path
        if let existingIndex = items.firstIndex(where: { $0.path == path }) {
            var existing = items.remove(at: existingIndex)
            existing.openedAt = Date()
            existing.title = title
            if let refreshed = probe.refreshedBookmark {
                existing.bookmarkData = refreshed
            }
            items.insert(existing, at: 0)
            setAvailability(.available(url.standardizedFileURL), for: existing.id)
            save()
            return
        }

        guard let bookmark = probe.newBookmark else { return }
        let item = RecentItem(
            id: UUID(),
            path: path,
            title: title,
            openedAt: Date(),
            bookmarkData: bookmark,
            isDirectory: probe.isDirectory
        )
        items.insert(item, at: 0)
        setAvailability(.available(url.standardizedFileURL), for: item.id)

        if items.count > Self.maxItems {
            let retained = Array(items.prefix(Self.maxItems))
            let retainedIDs = Set(retained.map(\.id))
            items = retained
            availabilityByID = availabilityByID.filter { retainedIDs.contains($0.key) }
        }

        save()
    }

    /// Assigns only a real change. Every assignment notifies observers and
    /// bumps `revision`, whatever the value; the availability sweep on each
    /// app activation mostly confirms what's already known, and shouldn't
    /// invalidate the sidebar and the Continue Reading index for that.
    private func setAvailability(_ availability: RecentItemAvailability, for id: UUID) {
        guard availabilityByID[id] != availability else { return }
        availabilityByID[id] = availability
    }

    /// `allowingMount: false` for lookups the user didn't ask for (see
    /// `SecurityScopedBookmarking.resolve(_:allowingMount:)`).
    func resolve(_ item: RecentItem, allowingMount: Bool = true) -> URL? {
        let result = bookmarks.resolveRefreshing(item.bookmarkData, allowingMount: allowingMount)
            .map { ResolvedBookmark(url: $0.url, refreshed: $0.refreshed) }
        return applyResolution(result, to: item)
    }

    /// `resolve`, with the resolution itself off the main thread: it may mount
    /// the item's volume, which can stall for seconds on a network share.
    func resolveOffMain(_ item: RecentItem, allowingMount: Bool = true) async -> URL? {
        let bookmarks = bookmarks
        let data = item.bookmarkData
        let result = await Task.detached(priority: .userInitiated) {
            bookmarks.resolveRefreshing(data, allowingMount: allowingMount)
                .map { ResolvedBookmark(url: $0.url, refreshed: $0.refreshed) }
        }.value
        return applyResolution(result, to: item)
    }

    private func applyResolution(_ result: ResolvedBookmark?, to item: RecentItem) -> URL? {
        guard let result else {
            setAvailability(.invalidBookmark, for: item.id)
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
        setAvailability(.available(url), for: item.id)
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
    /// A background sweep: it never mounts a volume, so a recent book on an
    /// unmounted share reads as temporarily unavailable until it's opened.
    func refreshAvailability() async -> [RecentItemPathMigration] {
        let snapshot = items
        let checks = await withTaskGroup(
            of: (UUID, BookmarkAvailabilityCheck).self,
            returning: [(UUID, BookmarkAvailabilityCheck)].self
        ) { group in
            for item in snapshot {
                let bookmarks = self.bookmarks
                group.addTask {
                    (item.id, Self.checkAvailability(of: item, bookmarks: bookmarks, allowingMount: false))
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
            // The user is opening it: mounting its volume is the point.
            Self.checkAvailability(of: item, bookmarks: bookmarks, allowingMount: true)
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
        bookmarks: any SecurityScopedBookmarking,
        allowingMount: Bool
    ) -> BookmarkAvailabilityCheck {
        guard let result = bookmarks.resolveRefreshing(
            item.bookmarkData,
            allowingMount: allowingMount
        ) else {
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
            setAvailability(.invalidBookmark, for: item.id)
            return RecentItemRefreshResult(availability: .invalidBookmark, migration: nil)
        case .temporarilyUnavailable:
            setAvailability(.temporarilyUnavailable, for: item.id)
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
            setAvailability(availability, for: item.id)
            let migration = oldPath == newPath
                ? nil
                : RecentItemPathMigration(oldPath: oldPath, newPath: newPath)
            return RecentItemRefreshResult(availability: availability, migration: migration)
        }
    }
}
