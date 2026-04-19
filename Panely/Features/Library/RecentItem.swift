import Foundation

nonisolated struct RecentItem: Identifiable, Sendable, Codable {
    var id: UUID
    var path: String
    var title: String
    var openedAt: Date
    var bookmarkData: Data
    var isDirectory: Bool

    var iconName: String {
        isDirectory ? "folder" : "book.closed"
    }

    init(
        id: UUID,
        path: String,
        title: String,
        openedAt: Date,
        bookmarkData: Data,
        isDirectory: Bool
    ) {
        self.id = id
        self.path = path
        self.title = title
        self.openedAt = openedAt
        self.bookmarkData = bookmarkData
        self.isDirectory = isDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        title = try container.decode(String.self, forKey: .title)
        openedAt = try container.decode(Date.self, forKey: .openedAt)
        bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)
        isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
    }
}
