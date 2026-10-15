import Foundation

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
    func readingBadge(for url: URL) -> ReadingBadge? {
        let keys = readingBadgeKeys(for: url)
        if let progress = readingProgress.progress(forKey: keys.primary, fileIdentityKey: keys.fileIdentity) {
            if progress.finished { return .finished }
            return .inProgress(fraction: progress.total > 0 ? progress.fraction : nil)
        }
        let index = positions.restoredIndex(forKey: keys.primary, fileIdentityKey: keys.fileIdentity)
        return index > 0 ? .inProgress(fraction: nil) : nil
    }

    struct ContinueReadingMemo {
        struct Inputs: Equatable {
            let progressRevision: Int
            let recentsRevision: Int
            let refreshToken: UUID
            let unavailableKeys: Set<String>
        }
        let inputs: Inputs
        let suggestion: ContinueReadingSuggestion?
    }

    /// The structural half of the Continue Reading scan: which progress keys
    /// belong to which available recent source (prefix matches over every
    /// key), and the file-identity alias of each (a stat per key). None of
    /// that moves when a page turn rewrites an existing record, so it's kept
    /// until recents, the progress *key set*, or the library tree change —
    /// a page turn then only re-reads the records these slots point at.
    struct ContinueReadingIndexMemo {
        struct Inputs: Equatable {
            let recentsRevision: Int
            let progressKeysRevision: Int
            let refreshToken: UUID
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

    /// `PositionKey.keys` stats the file for its identity; the sidebar asks
    /// for every visible row on every render. Keys only depend on the URL and
    /// the opened/temp context, so they're kept until that context changes or
    /// the library tree is re-scanned (files may have been replaced on disk).
    struct ReadingBadgeKeyMemo {
        struct Context: Equatable {
            let opened: URL?
            let tempRoot: URL?
            let refreshToken: UUID
        }
        var context: Context?
        var keys: [URL: PositionKey.Keys] = [:]
    }

    private func readingBadgeKeys(for url: URL) -> PositionKey.Keys {
        let context = ReadingBadgeKeyMemo.Context(
            opened: openedSourceURL,
            tempRoot: tempDir.url,
            refreshToken: libraryRefreshToken
        )
        if readingBadgeKeyMemo.context != context {
            readingBadgeKeyMemo = ReadingBadgeKeyMemo(context: context)
        }
        if let cached = readingBadgeKeyMemo.keys[url] { return cached }
        let keys = PositionKey.keys(for: url, opened: context.opened, tempRoot: context.tempRoot)
        readingBadgeKeyMemo.keys[url] = keys
        return keys
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
        // dependency on both stores alive when the memo hits. The refresh
        // token re-derives the cached file identities after a tree rescan.
        let inputs = ContinueReadingMemo.Inputs(
            progressRevision: readingProgress.revision,
            recentsRevision: recentItems.revision,
            refreshToken: libraryRefreshToken,
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
            recentItems.record(url, title: displayTitle(for: url))
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
            recentItems.record(url, title: displayTitle(for: url))
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
            refreshToken: libraryRefreshToken
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
        let keys = PositionKey.keys(for: url, opened: nil, tempRoot: nil)
        // The source's own record, or its file-identity alias.
        var slots = [
            ContinueReadingSlot(
                key: keys.primary,
                item: item,
                relativePath: nil,
                fileIdentityKey: keys.fileIdentity,
                isFolderChild: false
            ),
        ]

        let nestedPrefix = keys.primary + "#"
        for key in readingProgress.entries.keys where key.hasPrefix(nestedPrefix) {
            let relativePath = String(key.dropFirst(nestedPrefix.count))
            guard !relativePath.isEmpty else { continue }
            slots.append(ContinueReadingSlot(
                key: key,
                item: item,
                relativePath: relativePath,
                fileIdentityKey: keys.fileIdentity.map { $0 + "#" + relativePath },
                isFolderChild: false
            ))
        }

        // A remembered container directory may resolve to a child volume.
        // Those normal on-disk books key progress by `root/relative/path`
        // rather than zip-in-zip's `root#inner` convention.
        if item.isDirectory {
            let childPrefix = keys.primary + "/"
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
                    fileIdentityKey: PositionKey.fileIdentity(for: childURL),
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
