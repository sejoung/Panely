import Foundation

/// Persisted per-book reading progress, keyed by `PositionKey`.
///
/// Distinct from `ReaderPositionStore`, which stores only the page index for
/// exact restore: this also carries the total page count and a finished flag
/// so the sidebar can show progress badges and the "Continue reading" row
/// without re-scanning (and re-opening) every book in the tree.
nonisolated struct ReadingProgress: Codable, Sendable, Equatable {
    /// 0-based index of the first visible page when progress was recorded.
    var page: Int
    /// Total pages in the book at record time.
    var total: Int
    /// True when the last page/spread had been reached (`page + step >= total`).
    var finished: Bool
    var updatedAt: Date

    /// 0…1 share of the book read. `0` when the total is unknown.
    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(page + 1) / Double(total))
    }
}

/// What the sidebar renders for a book's reading state.
nonisolated enum ReadingBadge: Equatable {
    case finished
    /// In progress. `fraction` is `nil` when the total page count is unknown
    /// (a legacy position recorded before progress tracking existed) — the UI
    /// then shows a generic "reading" mark instead of a precise ring.
    case inProgress(fraction: Double?)
}
