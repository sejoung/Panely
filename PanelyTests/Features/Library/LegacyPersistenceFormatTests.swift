import Testing
import Foundation
@testable import Panely

/// Existing users' reading history lives in `UserDefaults` in the shapes
/// earlier releases wrote. These fixtures are hand-written in those shapes
/// (plain `JSONEncoder` output: dates as seconds since 2001, `Data` as
/// base64, optional fields absent) and loaded through a real, throwaway
/// `UserDefaults` suite — never the app's own domain — so a change to a
/// model's coding, the decoder configuration, or a store key that would
/// silently drop everyone's positions, progress, bookmarks, favorites or
/// recents fails here. The second half checks the reverse: what the current
/// stores write still decodes with the original decoder shape.
@MainActor
@Suite(.serialized)
struct LegacyPersistenceFormatTests {

    private static let bookPath = "/Volumes/Comics/Series/Vol01.cbz"
    private static let innerKey = "/Volumes/Comics/Series.cbz#Vol02.cbz"
    private static let bookmarkID = "6F1C1D8E-1B2A-4C3D-9E8F-0123456789AB"
    private static let itemID = "0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9"
    /// 2023-03-08T…Z as `timeIntervalSinceReferenceDate`.
    private static let savedAt: Double = 700_000_000

    @Test func legacyStoredDataStillLoads() throws {
        try withSuite { suite, store in
            seedLegacyData(in: suite)

            let positions = ReaderPositionStore(defaults: store)
            #expect(positions.restoredIndex(forKey: Self.bookPath, fileIdentityKey: nil) == 12)
            #expect(positions.restoredIndex(forKey: Self.innerKey, fileIdentityKey: nil) == 4)
            #expect(positions.restoredIndex(forKey: "moved", fileIdentityKey: "fid:1/2") == 33)

            let progress = ReadingProgressStore(defaults: store)
            let record = try #require(progress.progress(forKey: Self.bookPath, fileIdentityKey: nil))
            #expect(record == ReadingProgress(
                page: 12,
                total: 40,
                finished: false,
                updatedAt: Date(timeIntervalSinceReferenceDate: Self.savedAt)
            ))
            #expect(progress.progress(forKey: Self.innerKey, fileIdentityKey: nil)?.finished == true)

            let bookmarks = PageBookmarksStore(defaults: store)
            let marks = bookmarks.pageBookmarks(forKey: Self.bookPath)
            #expect(marks.map(\.pageIndex) == [3, 9])
            #expect(marks.first?.id == UUID(uuidString: Self.bookmarkID))
            #expect(marks.first?.createdAt == Date(timeIntervalSinceReferenceDate: Self.savedAt + 0.5))
            // A ref saved before `innerPath` / `bookmarkData` existed.
            let ref = try #require(bookmarks.bookRef(forKey: Self.bookPath))
            #expect(ref.title == "Vol01")
            #expect(ref.innerPath == nil)
            #expect(ref.bookmarkData == nil)

            let resolver = TestSecurityScopedBookmarkResolver()
            let favorites = FavoritesStore(bookmarks: resolver, defaults: store)
            let favorite = try #require(favorites.favorites.first)
            #expect(favorite.path == Self.bookPath)
            #expect(favorite.isDirectory == false)
            #expect(favorite.innerPath == nil)
            #expect(favorite.addedAt == Date(timeIntervalSinceReferenceDate: Self.savedAt))
            #expect(favorites.isFavorite(url: URL(fileURLWithPath: Self.bookPath)))

            let recents = RecentItemsStore(bookmarks: resolver, defaults: store)
            let recent = try #require(recents.items.first)
            #expect(recent.id == UUID(uuidString: Self.itemID))
            #expect(recent.path == Self.bookPath)
            #expect(recent.isDirectory == false)
            #expect(recent.bookmarkData == Data("file:///Volumes/Comics/Series/Vol01.cbz".utf8))
        }
    }

    @Test func currentWritesStayReadableByTheOriginalDecoderShape() throws {
        try withSuite { suite, store in
            let positions = ReaderPositionStore(defaults: store)
            positions.flushImmediately(forKey: Self.bookPath, fileIdentityKey: "fid:1/2", pageIndex: 5)

            let progress = ReadingProgressStore(defaults: store)
            progress.flushImmediately(forKey: Self.bookPath, fileIdentityKey: nil, page: 5, total: 40, finished: false)

            let bookmarks = PageBookmarksStore(defaults: store)
            bookmarks.togglePageBookmark(key: Self.bookPath, pageIndex: 7)
            bookmarks.setBookRef(
                PageBookmarkBookRef(title: "Vol01", path: Self.bookPath, innerPath: nil, isDirectory: false, bookmarkData: nil),
                forKey: Self.bookPath
            )

            // Positions: a plain property-list `[String: Int]`.
            let rawPositions = suite.dictionary(forKey: "panely.positions") as? [String: Int]
            #expect(rawPositions == [Self.bookPath: 5, "fid:1/2": 5])

            let decoder = JSONDecoder()
            let rawProgress = try decoder.decode(
                [String: LegacyProgress].self,
                from: try #require(suite.data(forKey: "panely.readingProgress"))
            )
            #expect(rawProgress[Self.bookPath]?.page == 5)
            #expect(rawProgress[Self.bookPath]?.total == 40)

            let rawBookmarks = try decoder.decode(
                [String: [LegacyBookmark]].self,
                from: try #require(suite.data(forKey: "panely.pageBookmarks"))
            )
            #expect(rawBookmarks[Self.bookPath]?.map(\.pageIndex) == [7])
            let rawRefs = try decoder.decode(
                [String: LegacyBookRef].self,
                from: try #require(suite.data(forKey: "panely.pageBookmarkBooks"))
            )
            #expect(rawRefs[Self.bookPath]?.title == "Vol01")
        }
    }

    // MARK: - Fixtures

    private func seedLegacyData(in suite: UserDefaults) {
        // Positions predate the MRU order list: no `panely.positions.order`.
        suite.set(
            [Self.bookPath: 12, Self.innerKey: 4, "fid:1/2": 33],
            forKey: "panely.positions"
        )
        suite.set(json("""
        {
          "\(Self.bookPath)": {"page": 12, "total": 40, "finished": false, "updatedAt": \(Self.savedAt)},
          "\(Self.innerKey)": {"page": 19, "total": 20, "finished": true, "updatedAt": \(Self.savedAt - 60)}
        }
        """), forKey: "panely.readingProgress")
        suite.set(json("""
        {
          "\(Self.bookPath)": [
            {"id": "\(Self.bookmarkID)", "pageIndex": 3, "createdAt": \(Self.savedAt + 0.5)},
            {"id": "7A1C1D8E-1B2A-4C3D-9E8F-0123456789AB", "pageIndex": 9, "createdAt": \(Self.savedAt + 1)}
          ]
        }
        """), forKey: "panely.pageBookmarks")
        suite.set(json("""
        {"\(Self.bookPath)": {"title": "Vol01", "path": "\(Self.bookPath)", "isDirectory": false}}
        """), forKey: "panely.pageBookmarkBooks")
        let bookmarkData = Data("file:///Volumes/Comics/Series/Vol01.cbz".utf8).base64EncodedString()
        // Favorites and recents from before `isDirectory` / `innerPath`.
        suite.set(json("""
        [{"id": "\(Self.itemID)", "path": "\(Self.bookPath)", "title": "Vol01",
          "addedAt": \(Self.savedAt), "bookmarkData": "\(bookmarkData)"}]
        """), forKey: "panely.favoriteBooks")
        suite.set(json("""
        [{"id": "\(Self.itemID)", "path": "\(Self.bookPath)", "title": "Vol01",
          "openedAt": \(Self.savedAt), "bookmarkData": "\(bookmarkData)"}]
        """), forKey: "panely.recentItems")
    }

    private func json(_ text: String) -> Data {
        Data(text.utf8)
    }

    /// A real `UserDefaults` suite (property-list round trip, `NSNumber`
    /// bridging) that is deleted afterwards. Never `.standard`.
    private func withSuite(_ body: (UserDefaults, LiveKeyValueStore) throws -> Void) throws {
        let name = "paneltest.legacy.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer {
            suite.removePersistentDomain(forName: name)
        }
        try body(suite, LiveKeyValueStore(defaults: suite))
    }

    // The shapes the first releases decoded, kept independent of the
    // current model types.
    private struct LegacyProgress: Decodable {
        let page: Int
        let total: Int
        let finished: Bool
        let updatedAt: Date
    }

    private struct LegacyBookmark: Decodable {
        let id: UUID
        let pageIndex: Int
        let createdAt: Date
    }

    private struct LegacyBookRef: Decodable {
        let title: String
        let path: String
        let isDirectory: Bool
    }
}
