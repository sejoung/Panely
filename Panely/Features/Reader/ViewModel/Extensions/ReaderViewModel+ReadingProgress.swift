import Foundation

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
        let innerPath: String?
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
        var best: ContinueReadingSuggestion?
        var bestUpdatedAt = Date.distantPast

        for item in recentItems.items {
            let url = URL(fileURLWithPath: item.path)
            let keys = PositionKey.keys(for: url, opened: nil, tempRoot: nil)
            var candidates: [(key: String, innerPath: String?, progress: ReadingProgress)] = []
            if let progress = readingProgress.progress(forKey: keys.primary, fileIdentityKey: keys.fileIdentity) {
                candidates.append((keys.primary, nil, progress))
            }

            let nestedPrefix = keys.primary + "#"
            for (key, progress) in readingProgress.entries where key.hasPrefix(nestedPrefix) {
                let innerPath = String(key.dropFirst(nestedPrefix.count))
                guard !innerPath.isEmpty else { continue }
                candidates.append((key, innerPath, progress))
            }

            for candidate in candidates where !candidate.progress.finished && candidate.progress.total > 0 {
                guard candidate.progress.updatedAt > bestUpdatedAt else { continue }
                bestUpdatedAt = candidate.progress.updatedAt
                let title = candidate.innerPath.map {
                    "\(item.title) · \(displayTitle(for: URL(fileURLWithPath: $0)))"
                } ?? item.title
                best = ContinueReadingSuggestion(
                    id: candidate.key,
                    title: title,
                    fraction: candidate.progress.fraction,
                    item: item,
                    innerPath: candidate.innerPath
                )
            }
        }
        return best
    }

    func openContinueReading(_ suggestion: ContinueReadingSuggestion) {
        guard let url = recentItems.resolve(suggestion.item) else { return }
        recentItems.record(url, title: displayTitle(for: url))
        Task { await load(url: url, intent: .favorite(innerPath: suggestion.innerPath)) }
    }
}
