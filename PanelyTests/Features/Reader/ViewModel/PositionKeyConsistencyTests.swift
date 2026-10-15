import Testing
import Foundation
@testable import Panely

/// Position, progress, page bookmarks, badges and favorites all file the open
/// book under keys derived by `PositionKey`. The view model now memoizes the
/// stat-heavy `PositionKey.keys` per opened book and derives the bookmark key
/// with the stat-free `PositionKey.make`; these tests pin both shortcuts to
/// the direct derivation for every way a book can be open, and pin the memo
/// to re-derive whenever its inputs (book, opened source, temp root, load)
/// change.
@MainActor
@Suite(.serialized)
struct PositionKeyConsistencyTests {

    enum Layout: String, CaseIterable {
        /// A book file opened on its own.
        case plainFile
        /// A volume archive listed inside an opened series folder.
        case folderListedVolume
        /// A volume extracted from an opened zip-in-zip archive.
        case zipInZipVolume
        /// A single-volume archive whose extraction root *is* the book.
        case extractionRoot
    }

    @Test(arguments: Layout.allCases)
    func everyStoreFilesTheOpenBookUnderTheDirectlyDerivedKeys(_ layout: Layout) throws {
        let work = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try makeFixture(layout, in: work)
        let vm = makeTestViewModel()
        vm.openedSourceURL = fixture.opened
        vm.tempDir.url = fixture.tempRoot
        vm.currentSourceURL = fixture.current
        vm.source = ComicSource(title: "t", pages: Fixture.makeImagePages(count: 10))

        let expected = PositionKey.keys(for: fixture.current, opened: fixture.opened, tempRoot: fixture.tempRoot)
        #expect(expected.fileIdentity != nil, "fixture files exist, so an identity is available")

        // Bookmark key: the stat-free path.
        #expect(vm.currentPositionKey == expected.primary)

        // Position + progress: both keys.
        vm.currentPageIndex = 3
        vm.flushPositionImmediately()
        #expect(vm.positions.cache?[expected.primary] == 3)
        #expect(vm.positions.cache?[try #require(expected.fileIdentity)] == 3)
        #expect(vm.readingProgress.entries[expected.primary]?.page == 3)
        #expect(vm.readingProgress.entries[try #require(expected.fileIdentity)]?.page == 3)
        #expect(vm.positions.cache?.count == 2)
        #expect(vm.readingProgress.entries.count == 2)
        // The badge, derived separately, finds the same record.
        #expect(vm.readingBadge(for: fixture.current) == .inProgress(fraction: 0.4))
        // So does the URL-addressed restore used on open.
        #expect(vm.restoredIndex(for: fixture.current) == 3)

        vm.toggleCurrentPageBookmark()
        #expect(Array(vm.pageBookmarks.pageBookmarksByBook.keys) == [expected.primary])
        #expect(vm.isCurrentPageBookmarked)

        // Favorites: the stat-free identity check agrees with the target the
        // toggle filed the favorite under.
        #expect(!vm.isCurrentBookFavorite)
        vm.toggleFavoriteForCurrentBook()
        #expect(vm.isCurrentBookFavorite)
        let favorite = try #require(vm.favorites.favorites.first)
        switch layout {
        case .zipInZipVolume:
            #expect(favorite.path == fixture.opened?.standardizedFileURL.path)
            #expect(favorite.innerPath == "Vol02.cbz")
        case .plainFile, .folderListedVolume:
            #expect(favorite.path == fixture.current.standardizedFileURL.path)
            #expect(favorite.innerPath == nil)
        case .extractionRoot:
            // No inner path to file it under; only the toggle/check agreement
            // above is pinned for this layout.
            break
        }
        vm.toggleFavoriteForCurrentBook()
        #expect(!vm.isCurrentBookFavorite)
    }

    @Test func memoRederivesTheIdentityWhenTheFileIsReplacedAndReloaded() async throws {
        let work = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let book = try Fixture.writeFile(work.appendingPathComponent("Book.cbz"), bytes: [1])
        let vm = makeTestViewModel()
        vm.currentSourceURL = book
        vm.source = ComicSource(title: "t", pages: Fixture.makeImagePages(count: 10))
        vm.currentPageIndex = 2
        vm.flushPositionImmediately()
        let oldIdentity = try #require(PositionKey.fileIdentity(for: book))

        // Replace the file on disk (an atomic save: new inode), then reload it.
        try Data([2, 3]).write(to: book, options: .atomic)
        // A reload resolves the path again. A fresh `URL`, not `book`: each
        // URL object caches its resource values until a run-loop pass, which
        // a busy main actor may not get to — reading through `book` here was
        // flaky under a full test run.
        let reloaded = URL(fileURLWithPath: book.path)
        let newIdentity = try #require(PositionKey.fileIdentity(for: reloaded))
        try #require(newIdentity != oldIdentity)
        vm.currentSourceURL = reloaded
        vm.loadEpoch &+= 1

        vm.currentPageIndex = 5
        vm.flushPositionImmediately()
        #expect(vm.positions.cache?[newIdentity] == 5)
        #expect(vm.readingProgress.entries[newIdentity]?.page == 5)
        #expect(vm.positions.cache?[oldIdentity] == 2)
    }

    @Test func memoFollowsTheOpenedSourceAndTempRoot() throws {
        let work = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let seriesA = try Fixture.writeFile(work.appendingPathComponent("SeriesA.cbz"))
        let seriesB = try Fixture.writeFile(work.appendingPathComponent("SeriesB.cbz"))
        // One extraction path reused for two archives (same inner layout).
        let tempRoot = work.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let volume = try Fixture.writeFile(tempRoot.appendingPathComponent("Vol01.cbz"))

        let vm = makeTestViewModel()
        vm.source = ComicSource(title: "t", pages: Fixture.makeImagePages(count: 10))
        vm.openedSourceURL = seriesA
        vm.tempDir.url = tempRoot
        vm.currentSourceURL = volume
        vm.currentPageIndex = 1
        vm.flushPositionImmediately()

        // Same book URL and load, different opened archive.
        vm.openedSourceURL = seriesB
        vm.currentPageIndex = 4
        vm.flushPositionImmediately()

        // Same book URL, opened archive and load; only the temp root changes.
        vm.tempDir.url = nil
        vm.currentPageIndex = 6
        vm.flushPositionImmediately()

        let keyA = PositionKey.keys(for: volume, opened: seriesA, tempRoot: tempRoot)
        let keyB = PositionKey.keys(for: volume, opened: seriesB, tempRoot: tempRoot)
        let plain = PositionKey.keys(for: volume, opened: nil, tempRoot: nil)
        #expect(Set([keyA.primary, keyB.primary, plain.primary]).count == 3)
        #expect(vm.readingProgress.entries[keyA.primary]?.page == 1)
        #expect(vm.readingProgress.entries[keyB.primary]?.page == 4)
        #expect(vm.readingProgress.entries[plain.primary]?.page == 6)
        #expect(vm.positions.cache?[try #require(keyA.fileIdentity)] == 1)
        #expect(vm.positions.cache?[try #require(keyB.fileIdentity)] == 4)
        #expect(vm.positions.cache?[try #require(plain.fileIdentity)] == 6)
    }

    // MARK: - Fixture

    private struct BookFixture {
        let opened: URL?
        let tempRoot: URL?
        let current: URL
    }

    private func makeFixture(_ layout: Layout, in work: URL) throws -> BookFixture {
        switch layout {
        case .plainFile:
            let book = try Fixture.writeFile(work.appendingPathComponent("Book.cbz"))
            return BookFixture(opened: book, tempRoot: nil, current: book)
        case .folderListedVolume:
            let series = work.appendingPathComponent("Series", isDirectory: true)
            try FileManager.default.createDirectory(at: series, withIntermediateDirectories: true)
            let volume = try Fixture.writeFile(series.appendingPathComponent("Vol02.cbz"))
            return BookFixture(opened: series, tempRoot: nil, current: volume)
        case .zipInZipVolume:
            let outer = try Fixture.writeFile(work.appendingPathComponent("Series.cbz"))
            let tempRoot = work.appendingPathComponent("extract", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            let volume = try Fixture.writeFile(tempRoot.appendingPathComponent("Vol02.cbz"))
            return BookFixture(opened: outer, tempRoot: tempRoot, current: volume)
        case .extractionRoot:
            let outer = try Fixture.writeFile(work.appendingPathComponent("Single.cbz"))
            let tempRoot = work.appendingPathComponent("extract", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            try Fixture.writeFile(tempRoot.appendingPathComponent("001.png"))
            return BookFixture(opened: outer, tempRoot: tempRoot, current: tempRoot)
        }
    }
}
