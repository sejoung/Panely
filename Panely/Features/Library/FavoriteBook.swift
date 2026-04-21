import Foundation

/// A book the user has favorited. Persists a security-scoped bookmark so it
/// survives app launches, mirroring `RecentItem`'s approach.
nonisolated struct FavoriteBook: Identifiable, Sendable, Codable {
    var id: UUID
    var path: String
    var title: String
    var addedAt: Date
    var bookmarkData: Data
    var isDirectory: Bool

    var iconName: String {
        isDirectory ? "folder" : "doc.zipper"
    }

    init(
        id: UUID,
        path: String,
        title: String,
        addedAt: Date,
        bookmarkData: Data,
        isDirectory: Bool
    ) {
        self.id = id
        self.path = path
        self.title = title
        self.addedAt = addedAt
        self.bookmarkData = bookmarkData
        self.isDirectory = isDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        title = try container.decode(String.self, forKey: .title)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)
        isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
    }
}
