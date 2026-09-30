import Testing
import Foundation
@testable import Panely

/// The cross-book bookmark list: bookmarking records how to get back to the
/// book, and picking a bookmark that lives in another book opens that book on
/// the bookmarked page.
@MainActor
struct ReaderViewModelBookmarkListTests {

    @Test func bookmarkingRecordsHowToReopenTheBook() async throws {
        let library = try makeLibrary(books: ["Alpha": 6])
        defer { try? FileManager.default.removeItem(at: library) }
        let alpha = library.appendingPathComponent("Alpha", isDirectory: true)
        let vm = makeTestViewModel()

        await vm.load(url: alpha)
        vm.jump(to: 3)
        vm.toggleCurrentPageBookmark()

        let key = try #require(vm.currentPositionKey)
        let ref = try #require(vm.pageBookmarks.bookRef(forKey: key))
        #expect(ref.title == "Alpha")
        #expect(ref.path == alpha.standardizedFileURL.path)
        #expect(ref.innerPath == nil)
        #expect(ref.isDirectory)
        #expect(ref.bookmarkData != nil)
    }

    @Test func otherBookmarkedBooksListsEveryBookButTheOpenOne() async throws {
        let library = try makeLibrary(books: ["Alpha": 6, "Beta": 6])
        defer { try? FileManager.default.removeItem(at: library) }
        let vm = makeTestViewModel()

        await vm.load(url: library.appendingPathComponent("Alpha", isDirectory: true))
        vm.jump(to: 2)
        vm.toggleCurrentPageBookmark()
        #expect(vm.otherBookmarkedBooks.isEmpty)

        await vm.load(url: library.appendingPathComponent("Beta", isDirectory: true))

        #expect(vm.currentBookPageBookmarks.isEmpty)
        #expect(vm.otherBookmarkedBooks.map(\.title) == ["Alpha"])
        #expect(vm.otherBookmarkedBooks.first?.bookmarks.map(\.pageIndex) == [2])
        #expect(vm.hasAnyPageBookmarks)
    }

    @Test func openingBookmarkInAnotherBookLandsOnTheBookmarkedPage() async throws {
        let library = try makeLibrary(books: ["Alpha": 8, "Beta": 4])
        defer { try? FileManager.default.removeItem(at: library) }
        let alpha = library.appendingPathComponent("Alpha", isDirectory: true)
        let vm = makeTestViewModel()
        vm.layout = .single

        await vm.load(url: alpha)
        vm.jump(to: 5)
        vm.toggleCurrentPageBookmark()
        // Leave Alpha's reading position somewhere else, so landing on page 5
        // can only come from the bookmark — not from position restore.
        vm.jump(to: 1)
        await vm.load(url: library.appendingPathComponent("Beta", isDirectory: true))

        let book = try #require(vm.otherBookmarkedBooks.first)
        let bookmark = try #require(book.bookmarks.first)
        vm.openBookmark(bookmark, in: book)
        try await waitUntil { vm.currentSourceURL?.lastPathComponent == "Alpha" && !vm.isLoading }

        #expect(vm.currentPageIndex == 5)
        #expect(vm.isCurrentPageBookmarked)
        #expect(vm.errorMessage == nil)
    }

    @Test func openingBookmarkInTheOpenBookJustJumps() async throws {
        let library = try makeLibrary(books: ["Alpha": 8])
        defer { try? FileManager.default.removeItem(at: library) }
        let vm = makeTestViewModel()
        vm.layout = .single

        await vm.load(url: library.appendingPathComponent("Alpha", isDirectory: true))
        vm.jump(to: 6)
        vm.toggleCurrentPageBookmark()
        vm.jump(to: 0)
        let epoch = vm.loadEpoch

        let key = try #require(vm.currentPositionKey)
        let book = try #require(vm.pageBookmarks.bookmarkedBooks().first { $0.key == key })
        vm.openBookmark(try #require(book.bookmarks.first), in: book)

        #expect(vm.currentPageIndex == 6)
        #expect(vm.loadEpoch == epoch) // no reload
    }

    @Test func bookmarkForVanishedBookReportsInsteadOfOpening() async throws {
        let vm = makeTestViewModel()
        vm.pageBookmarks.pageBookmarksByBook = [
            "/nowhere/Gone.cbz": [PageBookmark(pageIndex: 2)],
        ]

        let book = try #require(vm.otherBookmarkedBooks.first)
        vm.openBookmark(try #require(book.bookmarks.first), in: book)

        #expect(vm.errorMessage == "This bookmarked book can no longer be opened.")
        #expect(vm.currentSourceURL == nil)
    }

    @Test func removeAllPageBookmarksInCurrentBookLeavesOtherBooksAlone() async throws {
        let library = try makeLibrary(books: ["Alpha": 6, "Beta": 6])
        defer { try? FileManager.default.removeItem(at: library) }
        let vm = makeTestViewModel()
        vm.layout = .single

        await vm.load(url: library.appendingPathComponent("Alpha", isDirectory: true))
        vm.jump(to: 1)
        vm.toggleCurrentPageBookmark()
        await vm.load(url: library.appendingPathComponent("Beta", isDirectory: true))
        for page in [2, 4] {
            vm.jump(to: page)
            vm.toggleCurrentPageBookmark()
        }

        vm.removeAllPageBookmarksInCurrentBook()

        #expect(vm.hasPageBookmarks == false)
        #expect(vm.otherBookmarkedBooks.map(\.title) == ["Alpha"])
    }

    // MARK: helpers

    /// A folder of image-folder books: `<library>/<name>/000.png…`.
    private func makeLibrary(books: [String: Int]) throws -> URL {
        let library = try Fixture.makeTempDir()
        let png = try Fixture.makePNG(width: 10, height: 10)
        for (name, pageCount) in books {
            let book = library.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
            for index in 0..<pageCount {
                try png.write(to: book.appendingPathComponent(String(format: "%03d.png", index)))
            }
        }
        return library
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
