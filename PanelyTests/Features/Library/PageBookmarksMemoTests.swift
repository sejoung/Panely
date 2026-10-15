import Testing
import Foundation
@testable import Panely

/// `PageBookmarksStore.bookmarkedBooks` is memoized on `revision`. After any
/// mutation the memoized list must equal a from-scratch computation — here,
/// a fresh store loaded from the same key-value store, which also proves
/// every mutation was persisted. Plus the recency caps that bound history.
@MainActor
@Suite(.serialized)
struct PageBookmarksMemoTests {

    @Test(arguments: [UInt64(3), 17, 123, 4096])
    func memoizedListMatchesAFreshComputationAfterEveryMutation(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let defaults = InMemoryKeyValueStore()
        let store = PageBookmarksStore(defaults: defaults)
        let keys = [
            "/lib/A.cbz", "/lib/B.cbz", "/lib/Series.cbz#Vol01", "/lib/Series.cbz#Vol02",
            "/moved/A.cbz", "/moved/Series.cbz#Vol01", "/other/C", "fid:1/2",
        ]

        for step in 0..<300 {
            let key = keys.randomElement(using: &rng)!
            let label: String
            switch Int.random(in: 0..<100, using: &rng) {
            case 0..<40:
                let page = Int.random(in: 0..<6, using: &rng)
                store.togglePageBookmark(key: key, pageIndex: page)
                label = "toggle \(key) p\(page)"
            case 40..<55:
                let title = "T\(Int.random(in: 0..<4, using: &rng))"
                store.setBookRef(
                    PageBookmarkBookRef(title: title, path: key, innerPath: nil, isDirectory: false, bookmarkData: nil),
                    forKey: key
                )
                label = "ref \(key) \(title)"
            case 55..<63:
                if let bookmark = store.pageBookmarks(forKey: key).randomElement(using: &rng) {
                    store.removePageBookmark(forKey: key, id: bookmark.id)
                }
                label = "remove one in \(key)"
            case 63..<68:
                store.removeAllPageBookmarks(forKey: key)
                label = "remove all in \(key)"
            case 68..<76:
                let target = keys.randomElement(using: &rng)!
                store.moveBookmarks(fromKey: key, toKey: target)
                label = "move \(key) → \(target)"
            case 76..<84:
                if Bool.random(using: &rng) {
                    store.migrateSourcePath(from: "/lib/Series.cbz", to: "/moved/Series.cbz")
                    label = "migrate Series to /moved"
                } else {
                    store.migrateSourcePath(from: "/moved/A.cbz", to: "/lib/A.cbz")
                    label = "migrate A back to /lib"
                }
            case 84..<92:
                let keep = Set(keys.filter { _ in Bool.random(using: &rng) })
                store.pruneOrphaned(keeping: keep)
                label = "prune keeping \(keep.count)"
            case 92..<94:
                store.removeAll()
                label = "remove everything"
            default:
                // Add and take back: no net change, two revisions.
                let page = 100 + step
                store.togglePageBookmark(key: key, pageIndex: page)
                store.togglePageBookmark(key: key, pageIndex: page)
                label = "toggle and untoggle \(key)"
            }

            let comment = Comment(rawValue: "seed \(seed) step \(step): \(label)")
            #expect(store.bookmarkedBooks() == expectedBooks(store), comment)
            // What a relaunch loads: every mutation persisted.
            #expect(PageBookmarksStore(defaults: defaults).bookmarkedBooks() == store.bookmarkedBooks(), comment)
            let excluded = keys.randomElement(using: &rng)!
            #expect(
                store.bookmarkedBooks(excluding: excluded) == expectedBooks(store).filter { $0.key != excluded },
                comment
            )
        }
    }

    @Test func capByRecencyKeepsExactlyTheNewestEntries() {
        var rng = SeededGenerator(seed: 11)
        var dict: [String: Date] = [:]
        for index in 0..<60 {
            dict["k\(index)"] = Date(timeIntervalSinceReferenceDate: Double.random(in: 0..<1_000_000, using: &rng))
        }
        let newest = Set(dict.sorted { $0.value > $1.value }.prefix(10).map(\.key))

        var capped = dict
        capped.capByRecency(to: 10) { $0 }
        #expect(Set(capped.keys) == newest)

        var untouched = dict
        untouched.capByRecency(to: 60) { $0 }
        #expect(untouched == dict)
    }

    @Test func bookCapEvictsTheLeastRecentlyBookmarkedBookAndItsRef() {
        let store = PageBookmarksStore(defaults: InMemoryKeyValueStore())
        let base = Date().addingTimeInterval(-10_000)
        var staged: [String: [PageBookmark]] = [:]
        for index in 0..<PageBookmarksStore.maxBookEntries {
            // A book's recency is its newest bookmark, not its oldest.
            staged["/lib/\(index).cbz"] = [
                PageBookmark(pageIndex: 0, createdAt: base.addingTimeInterval(Double(index))),
                PageBookmark(pageIndex: 1, createdAt: base.addingTimeInterval(Double(index) - 5_000)),
            ]
        }
        // Old first bookmark, but touched most recently of the staged books.
        staged["/lib/0.cbz"]?.append(PageBookmark(pageIndex: 2, createdAt: base.addingTimeInterval(500)))
        store.pageBookmarksByBook = staged
        store.setBookRef(
            PageBookmarkBookRef(title: "One", path: "/lib/1.cbz", innerPath: nil, isDirectory: false, bookmarkData: nil),
            forKey: "/lib/1.cbz"
        )

        store.togglePageBookmark(key: "/lib/new.cbz", pageIndex: 3)

        #expect(store.pageBookmarksByBook.count == PageBookmarksStore.maxBookEntries)
        #expect(store.pageBookmarksByBook["/lib/1.cbz"] == nil)
        #expect(store.bookRef(forKey: "/lib/1.cbz") == nil)
        #expect(store.pageBookmarksByBook["/lib/0.cbz"] != nil)
        #expect(store.pageBookmarksByBook["/lib/new.cbz"] != nil)
        #expect(store.pageBookmarksByBook["/lib/2.cbz"] != nil)
    }

    /// Independent restatement of the documented order: newest bookmark
    /// first, key as the tie-break.
    private func expectedBooks(_ store: PageBookmarksStore) -> [BookmarkedBook] {
        store.pageBookmarksByBook
            .filter { !$0.value.isEmpty }
            .map { key, bookmarks in
                (
                    BookmarkedBook(
                        key: key,
                        title: store.title(forKey: key),
                        folderName: store.folderName(forKey: key),
                        bookmarks: bookmarks
                    ),
                    bookmarks.map(\.createdAt).max()!
                )
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.key < $1.0.key }
            .map(\.0)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
