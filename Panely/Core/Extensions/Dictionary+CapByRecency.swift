import Foundation

extension Dictionary {
    /// Keep at most `limit` entries, evicting those whose `recency` is oldest
    /// first. No-op when already within the limit.
    ///
    /// Shared by the persistence stores that bound history by "most recently
    /// touched" (`ReadingProgressStore` by `updatedAt`, `PageBookmarksStore` by
    /// each book's newest bookmark). `ReaderPositionStore` deliberately does
    /// *not* use this — its values are bare page indices with no embedded date,
    /// so it tracks recency in a separate persisted order list instead.
    mutating func capByRecency(to limit: Int, recency: (Value) -> Date) {
        guard count > limit else { return }
        let overflow = count - limit
        let stale = sorted { recency($0.value) < recency($1.value) }
            .prefix(overflow)
            .map(\.key)
        for key in stale {
            removeValue(forKey: key)
        }
    }
}
