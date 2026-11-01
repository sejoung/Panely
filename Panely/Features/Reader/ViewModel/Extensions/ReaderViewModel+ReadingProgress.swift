import Foundation

/// A row's identity lookup, with the opened/temp context its key depends on.
nonisolated struct BadgeIdentityRequest: Hashable, Sendable {
    let url: URL
    let opened: URL?
    let tempRoot: URL?
}

/// Values that need the file system to compute, for readers that can't wait:
/// a miss answers `nil` now and is looked up off the main thread, together
/// with whatever else was asked for in the same run-loop pass.
///
/// `reader.value(for:)` runs in SwiftUI `body`, on the main thread, for every
/// row of a library that may live on a network share — where a stat per row
/// is a visible hang, and an unresponsive mount a long one.
@MainActor
final class OffMainLookup<Key: Hashable & Sendable, Value: Hashable & Sendable> {
    private var known: [Key: Value?] = [:]
    private var pending: Set<Key> = []
    private var inFlight: Set<Key> = []
    private var task: Task<Void, Never>?
    private let compute: @Sendable (Key) -> Value?
    /// Called for each key whose value changed, after it is stored.
    var onChange: (Key, Value?) -> Void = { _, _ in }

    init(compute: @escaping @Sendable (Key) -> Value?) {
        self.compute = compute
    }

    func value(for key: Key) -> Value? {
        if let value = known[key] { return value }
        pending.insert(key)
        startIfNeeded()
        return nil
    }

    /// Look everything up again (files may have been replaced on disk). The
    /// old values keep answering until the new ones arrive.
    func refreshAll() {
        // Including those being looked up right now, which may have read the
        // file before whatever prompted this refresh changed it.
        pending.formUnion(known.keys)
        pending.formUnion(inFlight)
        guard !pending.isEmpty else { return }
        startIfNeeded()
    }

    /// Finishes when nothing is left to look up.
    func settled() async {
        while let task {
            await task.value
        }
    }

    private func startIfNeeded() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.drain()
            self?.task = nil
        }
    }

    private func drain() async {
        let compute = compute
        while !pending.isEmpty {
            let batch = pending
            pending = []
            inFlight = batch
            let results = await Task.detached(priority: .utility) {
                batch.map { (key: $0, value: compute($0)) }
            }.value
            inFlight = []
            for (key, value) in results {
                let changed = (known[key] ?? nil) != value
                known[key] = .some(value)
                if changed { onChange(key, value) }
            }
        }
    }
}

private nonisolated struct DirectoryContinueReadingAvailabilityCheck: Sendable {
    let root: URL
    let children: [(key: String, url: URL)]
}

/// Surfaces persisted reading progress to the sidebar: per-book badges and the
/// "Continue reading" suggestion. Reads `readingProgress` (and `positions` for
/// legacy graceful-degradation) so the UI never has to re-open a book to know
/// where the user left off.
extension ReaderViewModel {

    /// Badge for a tree/volume URL, or `nil` when the book has never been
    /// opened. Falls back to a total-less "in progress" mark for books that
    /// have a saved page index but no recorded progress (read before progress
    /// tracking existed).
    ///
    /// Read from row bodies, so it never touches the file system: the path key
    /// answers straight away, and the file-identity alias (which only matters
    /// for a moved or remounted book) joins in once `badgeIdentities` has
    /// stat'ed it in the background.
    func readingBadge(for url: URL) -> ReadingBadge? {
        // Observation dependency: an alias that turns out to hold this book's
        // record has to reach the rows that drew without it.
        _ = readingBadgeIdentityRevision
        let context = ReadingBadgeKeyMemo.Context(opened: openedSourceURL, tempRoot: tempDir.url)
        let primary = readingBadgePrimaryKey(for: url, context: context)
        let identity = badgeIdentities.value(
            for: BadgeIdentityRequest(url: url, opened: context.opened, tempRoot: context.tempRoot)
        )
        return readingBadge(primary: primary, fileIdentity: identity)
    }

    private func readingBadge(primary: String, fileIdentity: String?) -> ReadingBadge? {
        if let progress = readingProgress.progress(forKey: primary, fileIdentityKey: fileIdentity) {
            if progress.finished { return .finished }
            return .inProgress(fraction: progress.total > 0 ? progress.fraction : nil)
        }
        let index = positions.restoredIndex(forKey: primary, fileIdentityKey: fileIdentity)
        return index > 0 ? .inProgress(fraction: nil) : nil
    }

    /// A file identity arrived for `request`: re-render the badges only if it
    /// changes what this row shows — not for every book that has no record
    /// under its alias, which is nearly all of them.
    func badgeIdentityResolved(_ request: BadgeIdentityRequest, identity: String?) {
        let primary = PositionKey.make(for: request.url, opened: request.opened, tempRoot: request.tempRoot)
        if readingBadge(primary: primary, fileIdentity: identity)
            != readingBadge(primary: primary, fileIdentity: nil) {
            readingBadgeIdentityRevision &+= 1
        }
    }

    struct ContinueReadingMemo {
        struct Inputs: Equatable {
            let progressRevision: Int
            let recentsRevision: Int
            let identityRevision: Int
            let unavailableKeys: Set<String>
        }
        let inputs: Inputs
        let suggestion: ContinueReadingSuggestion?
    }

    /// The structural half of the Continue Reading scan: which progress keys
    /// belong to which available recent source (prefix matches over every
    /// key). None of that moves when a page turn rewrites an existing record,
    /// so it's kept until recents, the progress *key set*, or a file identity
    /// change — a page turn then only re-reads the records these slots point
    /// at. Identities come from `continueReadingIdentities`, so building this
    /// in `body` never stats a file.
    struct ContinueReadingIndexMemo {
        struct Inputs: Equatable {
            let recentsRevision: Int
            let progressKeysRevision: Int
            let identityRevision: Int
        }
        let inputs: Inputs
        /// In scan order (recents order; per source: the source itself,
        /// then archive-inner volumes, then folder children), which is also
        /// the tie-break order between equally fresh candidates.
        let slots: [ContinueReadingSlot]
    }

    struct ContinueReadingSlot {
        let key: String
        let item: RecentItem
        let relativePath: String?
        let fileIdentityKey: String?
        /// A book below a remembered container folder: hidden while
        /// `unavailableContinueReadingKeys` lists it.
        let isFolderChild: Bool
    }

    /// The path keys of the rows on screen, kept while the opened/temp context
    /// holds: the sidebar asks for every visible row on every render.
    struct ReadingBadgeKeyMemo {
        struct Context: Equatable {
            let opened: URL?
            let tempRoot: URL?
        }
        var context: Context?
        var primaryKeys: [URL: String] = [:]
    }

    private func readingBadgePrimaryKey(for url: URL, context: ReadingBadgeKeyMemo.Context) -> String {
        if readingBadgeKeyMemo.context != context {
            readingBadgeKeyMemo = ReadingBadgeKeyMemo(context: context)
        }
        if let cached = readingBadgeKeyMemo.primaryKeys[url] { return cached }
        let primary = PositionKey.make(for: url, opened: context.opened, tempRoot: context.tempRoot)
        readingBadgeKeyMemo.primaryKeys[url] = primary
        return primary
    }

    struct ContinueReadingSuggestion: Identifiable {
        let id: String
        let title: String
        let fraction: Double
        let item: RecentItem
        let relativePath: String?
        let fileIdentityKey: String?
    }

    /// The most-recently-read book that isn't finished, drawn from recents so
    /// it stays openable via its security-scoped bookmark. `nil` when nothing
    /// qualifies.
    ///
    /// Deliberately *includes* the book currently open: opening or flipping to
    /// a book bumps its `updatedAt`, so it surfaces here with live progress and
    /// the row tracks what you're actually reading. On a cold launch (nothing
    /// open) it resolves to whatever you read last — the primary use case.
    var continueReadingSuggestion: ContinueReadingSuggestion? {
        // Reading the revisions (not just the memo) keeps the observation
        // dependency on both stores alive when the memo hits.
        let inputs = ContinueReadingMemo.Inputs(
            progressRevision: readingProgress.revision,
            recentsRevision: recentItems.revision,
            identityRevision: continueReadingIdentityRevision,
            unavailableKeys: unavailableContinueReadingKeys
        )
        if let memo = continueReadingMemo, memo.inputs == inputs {
            return memo.suggestion
        }
        let suggestion = computeContinueReadingSuggestion(
            slots: continueReadingSlots(),
            unavailableKeys: inputs.unavailableKeys
        )
        continueReadingMemo = ContinueReadingMemo(inputs: inputs, suggestion: suggestion)
        return suggestion
    }

    /// The freshest unfinished record among `slots`; the first slot wins a
    /// tie. Two dictionary lookups per slot — no scanning, no stats.
    private func computeContinueReadingSuggestion(
        slots: [ContinueReadingSlot],
        unavailableKeys: Set<String>
    ) -> ContinueReadingSuggestion? {
        var best: (slot: ContinueReadingSlot, progress: ReadingProgress)?
        var bestUpdatedAt = Date.distantPast

        for slot in slots {
            if slot.isFolderChild, unavailableKeys.contains(slot.key) { continue }
            guard let progress = readingProgress.mostRecentProgress(
                forKey: slot.key,
                fileIdentityKey: slot.fileIdentityKey
            ),
                  !progress.finished,
                  progress.total > 0,
                  progress.updatedAt > bestUpdatedAt
            else { continue }
            bestUpdatedAt = progress.updatedAt
            best = (slot, progress)
        }
        return best.map {
            ContinueReadingSuggestion(
                id: $0.slot.key,
                title: continueReadingTitle(for: $0.slot.item, relativePath: $0.slot.relativePath),
                fraction: $0.progress.fraction,
                item: $0.slot.item,
                relativePath: $0.slot.relativePath,
                fileIdentityKey: $0.slot.fileIdentityKey
            )
        }
    }

    func openContinueReading(_ suggestion: ContinueReadingSuggestion) {
        Task {
            let result = await recentItems.refreshAvailability(for: suggestion.item)
            applyRecentItemMigration(result.migration)
            guard case .available(let url) = result.availability else {
                presentUnavailableRecentItem(suggestion.item, availability: result.availability)
                return
            }
            unavailableRecentItem = nil
            recentItems.recordInBackground(url, title: displayTitle(for: url))
            await load(
                url: url,
                intent: .continueReading(relativePath: suggestion.relativePath)
            )
        }
    }

    func openRecentItem(_ item: RecentItem) {
        Task {
            let result = await recentItems.refreshAvailability(for: item)
            applyRecentItemMigration(result.migration)
            guard case .available(let url) = result.availability else {
                presentUnavailableRecentItem(item, availability: result.availability)
                return
            }
            unavailableRecentItem = nil
            recentItems.recordInBackground(url, title: displayTitle(for: url))
            await load(url: url)
        }
    }

    func refreshContinueReadingAvailability() async {
        continueReadingAvailabilityRefreshGeneration &+= 1
        let generation = continueReadingAvailabilityRefreshGeneration
        let migrations = await recentItems.refreshAvailability()
        guard generation == continueReadingAvailabilityRefreshGeneration else { return }
        for migration in migrations { applyRecentItemMigration(migration) }

        let checks = directoryContinueReadingAvailabilityChecks()
        let unavailableKeys = await Task.detached(priority: .utility) {
            Self.unavailableDirectoryContinueReadingKeys(in: checks)
        }.value
        guard generation == continueReadingAvailabilityRefreshGeneration else { return }
        unavailableContinueReadingKeys = unavailableKeys
    }

    func removeContinueReading(_ suggestion: ContinueReadingSuggestion) {
        readingProgress.remove(
            forKey: suggestion.id,
            fileIdentityKey: suggestion.fileIdentityKey
        )
    }

    func removeUnavailableRecentItem() {
        guard let item = unavailableRecentItem else { return }
        readingProgress.removeEntries(forSourcePath: item.path)
        recentItems.remove(item)
        unavailableRecentItem = nil
        errorMessage = nil
    }

    private func continueReadingSlots() -> [ContinueReadingSlot] {
        let inputs = ContinueReadingIndexMemo.Inputs(
            recentsRevision: recentItems.revision,
            progressKeysRevision: readingProgress.keysRevision,
            identityRevision: continueReadingIdentityRevision
        )
        if let memo = continueReadingIndexMemo, memo.inputs == inputs {
            return memo.slots
        }
        let slots = recentItems.items.flatMap { continueReadingSlots(for: $0) }
        continueReadingIndexMemo = ContinueReadingIndexMemo(inputs: inputs, slots: slots)
        return slots
    }

    private func continueReadingSlots(for item: RecentItem) -> [ContinueReadingSlot] {
        guard let url = recentItems.availableURL(for: item) else { return [] }
        let primary = PositionKey.make(for: url, opened: nil, tempRoot: nil)
        let identity = continueReadingIdentities.value(for: url)
        // The source's own record, or its file-identity alias.
        var slots = [
            ContinueReadingSlot(
                key: primary,
                item: item,
                relativePath: nil,
                fileIdentityKey: identity,
                isFolderChild: false
            ),
        ]

        let nestedPrefix = primary + "#"
        for key in readingProgress.entries.keys where key.hasPrefix(nestedPrefix) {
            let relativePath = String(key.dropFirst(nestedPrefix.count))
            guard !relativePath.isEmpty else { continue }
            slots.append(ContinueReadingSlot(
                key: key,
                item: item,
                relativePath: relativePath,
                fileIdentityKey: identity.map { $0 + "#" + relativePath },
                isFolderChild: false
            ))
        }

        // A remembered container directory may resolve to a child volume.
        // Those normal on-disk books key progress by `root/relative/path`
        // rather than zip-in-zip's `root#inner` convention.
        if item.isDirectory {
            let childPrefix = primary + "/"
            for key in readingProgress.entries.keys
            where key.hasPrefix(childPrefix) && !key.contains("#") {
                let relativePath = String(key.dropFirst(childPrefix.count))
                let childURL = url
                    .appendingPathComponent(relativePath)
                    .standardizedFileURL
                guard !relativePath.isEmpty, url.isAncestor(of: childURL) else { continue }
                slots.append(ContinueReadingSlot(
                    key: key,
                    item: item,
                    relativePath: relativePath,
                    fileIdentityKey: continueReadingIdentities.value(for: childURL),
                    isFolderChild: true
                ))
            }
        }
        return slots
    }

    private func continueReadingTitle(for item: RecentItem, relativePath: String?) -> String {
        guard let relativePath else { return item.title }
        let innerTitle = displayTitle(for: URL(fileURLWithPath: relativePath))
        return "\(item.title) · \(innerTitle)"
    }

    /// Re-key everything filed under a source's old path after its bookmark
    /// resolves somewhere new. Shared with the page-bookmark open path.
    func applyRecentItemMigration(_ migration: RecentItemPathMigration?) {
        guard let migration else { return }
        readingProgress.migrateSourcePath(from: migration.oldPath, to: migration.newPath)
        positions.migrateSourcePath(from: migration.oldPath, to: migration.newPath)
        pageBookmarks.migrateSourcePath(from: migration.oldPath, to: migration.newPath)
    }

    private func directoryContinueReadingAvailabilityChecks()
        -> [DirectoryContinueReadingAvailabilityCheck] {
        recentItems.items.compactMap { item in
            guard item.isDirectory,
                  let root = recentItems.availableURL(for: item) else { return nil }
            let prefix = root.standardizedFileURL.path + "/"
            let children = readingProgress.entries.keys.compactMap { key -> (String, URL)? in
                guard key.hasPrefix(prefix), !key.contains("#") else { return nil }
                let relativePath = String(key.dropFirst(prefix.count))
                guard !relativePath.isEmpty else { return nil }
                let child = root
                    .appendingPathComponent(relativePath)
                    .standardizedFileURL
                guard root.isAncestor(of: child) else { return nil }
                return (key, child)
            }
            guard !children.isEmpty else { return nil }
            return DirectoryContinueReadingAvailabilityCheck(
                root: root,
                children: children
            )
        }
    }

    private nonisolated static func unavailableDirectoryContinueReadingKeys(
        in checks: [DirectoryContinueReadingAvailabilityCheck]
    ) -> Set<String> {
        var unavailable: Set<String> = []
        for check in checks {
            let didStart = check.root.startAccessingSecurityScopedResource()
            defer { if didStart { check.root.stopAccessingSecurityScopedResource() } }
            for child in check.children
            where (try? child.url.checkResourceIsReachable()) != true {
                unavailable.insert(child.key)
            }
        }
        return unavailable
    }

    private func presentUnavailableRecentItem(
        _ item: RecentItem,
        availability: RecentItemAvailability
    ) {
        unavailableRecentItem = item
        switch availability {
        case .temporarilyUnavailable:
            errorMessage = String(localized: "This book is currently unavailable. Reconnect its drive or restore the file.", bundle: .localized)
        case .invalidBookmark, .unknown:
            errorMessage = String(localized: "This recent book can no longer be opened.", bundle: .localized)
        case .available:
            break
        }
    }
}
