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
    }

    /// The most-recently-read book that's still in progress (not finished, not
    /// the one currently open), drawn from recents so it stays openable via
    /// its security-scoped bookmark. `nil` when nothing qualifies.
    var continueReadingSuggestion: ContinueReadingSuggestion? {
        let openedPath = openedSourceURL?.standardizedFileURL.path
        var best: ContinueReadingSuggestion?
        var bestUpdatedAt = Date.distantPast

        for item in recentItems.items {
            let url = URL(fileURLWithPath: item.path)
            if url.standardizedFileURL.path == openedPath { continue }
            let keys = PositionKey.keys(for: url, opened: nil, tempRoot: nil)
            guard let progress = readingProgress.progress(forKey: keys.primary, fileIdentityKey: keys.fileIdentity),
                  !progress.finished,
                  progress.total > 0,
                  progress.page > 0
            else { continue }

            if progress.updatedAt > bestUpdatedAt {
                bestUpdatedAt = progress.updatedAt
                best = ContinueReadingSuggestion(
                    id: keys.primary,
                    title: item.title,
                    fraction: progress.fraction,
                    item: item
                )
            }
        }
        return best
    }

    func openContinueReading(_ suggestion: ContinueReadingSuggestion) {
        guard let url = recentItems.resolve(suggestion.item) else { return }
        openURL(url)
    }
}
