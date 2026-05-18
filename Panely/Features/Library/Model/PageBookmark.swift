import Foundation

/// A user-pinned page within a specific book. Stored per-book keyed by the
/// stable `PositionKey`, so bookmarks survive temp-dir re-extractions just
/// like reading positions.
nonisolated struct PageBookmark: Identifiable, Sendable, Codable, Equatable {
    var id: UUID
    var pageIndex: Int
    var createdAt: Date

    init(id: UUID = UUID(), pageIndex: Int, createdAt: Date = Date()) {
        self.id = id
        self.pageIndex = pageIndex
        self.createdAt = createdAt
    }
}
