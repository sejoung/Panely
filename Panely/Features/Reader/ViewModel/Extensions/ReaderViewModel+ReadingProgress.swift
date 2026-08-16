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
        let keys = PositionKey.keys(for: url, opened: openedSourceURL, tempRoot: tempDir.url)
        if let progress = readingProgress.progress(forKey: keys.primary, fileIdentityKey: keys.fileIdentity) {
            if progress.finished { return .finished }
            return .inProgress(fraction: progress.total > 0 ? progress.fraction : nil)
        }
        let index = positions.restoredIndex(forKey: keys.primary, fileIdentityKey: keys.fileIdentity)
        return index > 0 ? .inProgress(fraction: nil) : nil
    }

    struct ContinueReadingSuggestion: Identifiable {
        let id: String
        let title: String
        let fraction: Double
        let item: RecentItem
        let relativePath: String?
        let fileIdentityKey: String?
    }

    private struct ContinueReadingCandidate {
        let key: String
        let title: String
        let fraction: Double
        let updatedAt: Date
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
        var best: ContinueReadingCandidate?
        var bestUpdatedAt = Date.distantPast

        for item in recentItems.items {
            for candidate in continueReadingCandidates(for: item) {
                guard candidate.updatedAt > bestUpdatedAt else { continue }
                bestUpdatedAt = candidate.updatedAt
                best = candidate
            }
        }
        return best.map {
            ContinueReadingSuggestion(
                id: $0.key,
                title: $0.title,
                fraction: $0.fraction,
                item: $0.item,
                relativePath: $0.relativePath,
                fileIdentityKey: $0.fileIdentityKey
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

    private func continueReadingCandidates(for item: RecentItem) -> [ContinueReadingCandidate] {
        guard let url = recentItems.availableURL(for: item) else { return [] }
        let keys = PositionKey.keys(for: url, opened: nil, tempRoot: nil)
        var candidates: [ContinueReadingCandidate] = []
        var includedKeys: Set<String> = []

        if let progress = readingProgress.mostRecentProgress(
            forKey: keys.primary,
            fileIdentityKey: keys.fileIdentity
        ),
           let candidate = continueReadingCandidate(
            key: keys.primary,
            item: item,
            relativePath: nil,
            fileIdentityKey: keys.fileIdentity,
            progress: progress
           ) {
            candidates.append(candidate)
            includedKeys.insert(keys.primary)
        }

        let nestedPrefix = keys.primary + "#"
        for (key, progress) in readingProgress.entries where key.hasPrefix(nestedPrefix) {
            let relativePath = String(key.dropFirst(nestedPrefix.count))
            let fileIdentityKey = PositionKey.fileIdentity(for: url)
                .map { $0 + "#" + relativePath }
            let freshest = readingProgress.mostRecentProgress(
                forKey: key,
                fileIdentityKey: fileIdentityKey
            ) ?? progress
            guard includedKeys.insert(key).inserted,
                  !relativePath.isEmpty,
                  let candidate = continueReadingCandidate(
                    key: key,
                    item: item,
                    relativePath: relativePath,
                    fileIdentityKey: fileIdentityKey,
                    progress: freshest
                  )
            else { continue }
            candidates.append(candidate)
        }

        // A remembered container directory may resolve to a child volume.
        // Those normal on-disk books key progress by `root/relative/path`
        // rather than zip-in-zip's `root#inner` convention.
        if item.isDirectory {
            let childPrefix = keys.primary + "/"
            for (key, progress) in readingProgress.entries
            where key.hasPrefix(childPrefix) && !key.contains("#") {
                let relativePath = String(key.dropFirst(childPrefix.count))
                let childURL = url
                    .appendingPathComponent(relativePath)
                    .standardizedFileURL
                let fileIdentityKey = PositionKey.fileIdentity(for: childURL)
                let freshest = readingProgress.mostRecentProgress(
                    forKey: key,
                    fileIdentityKey: fileIdentityKey
                ) ?? progress
                guard includedKeys.insert(key).inserted,
                      !relativePath.isEmpty,
                      url.isAncestor(of: childURL),
                      !unavailableContinueReadingKeys.contains(key),
                      let candidate = continueReadingCandidate(
                        key: key,
                        item: item,
                        relativePath: relativePath,
                        fileIdentityKey: fileIdentityKey,
                        progress: freshest
                      )
                else { continue }
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private func continueReadingCandidate(
        key: String,
        item: RecentItem,
        relativePath: String?,
        fileIdentityKey: String?,
        progress: ReadingProgress
    ) -> ContinueReadingCandidate? {
        guard !progress.finished, progress.total > 0 else { return nil }
        return ContinueReadingCandidate(
            key: key,
            title: continueReadingTitle(for: item, relativePath: relativePath),
            fraction: progress.fraction,
            updatedAt: progress.updatedAt,
            item: item,
            relativePath: relativePath,
            fileIdentityKey: fileIdentityKey
        )
    }

    private func continueReadingTitle(for item: RecentItem, relativePath: String?) -> String {
        guard let relativePath else { return item.title }
        let innerTitle = displayTitle(for: URL(fileURLWithPath: relativePath))
        return "\(item.title) · \(innerTitle)"
    }

    private func applyRecentItemMigration(_ migration: RecentItemPathMigration?) {
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
            errorMessage = "This book is currently unavailable. Reconnect its drive or restore the file."
        case .invalidBookmark, .unknown:
            errorMessage = "This recent book can no longer be opened."
        case .available:
            break
        }
    }
}
