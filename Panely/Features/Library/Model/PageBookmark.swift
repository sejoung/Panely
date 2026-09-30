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

/// How to get back to a bookmarked book when it isn't the one on screen.
/// Stored next to the book's bookmarks so the cross-book list can open it
/// without the user having to find the file again: `bookmarkData` is a
/// security-scoped bookmark for `path` (the outer archive for zip-in-zip,
/// otherwise the book itself), and `innerPath` names the volume inside it.
nonisolated struct PageBookmarkBookRef: Sendable, Codable, Equatable {
    var title: String
    var path: String
    var innerPath: String?
    var isDirectory: Bool
    var bookmarkData: Data?
}

/// One book's bookmarks, as listed outside that book (sidebar "Other Books",
/// the Go ▸ Bookmarks submenu, the toolbar bookmark menu).
nonisolated struct BookmarkedBook: Identifiable, Sendable, Equatable {
    let key: String
    let title: String
    /// Name of the folder the book sits in. Volume files are often just
    /// "Vol 03", so lists that mix books show this alongside the title.
    let folderName: String
    let bookmarks: [PageBookmark]

    var id: String { key }

    /// `folder / title` — unambiguous across series.
    var qualifiedTitle: String {
        folderName.isEmpty ? title : "\(folderName) / \(title)"
    }
}
