import Testing
import Foundation
@testable import Panely

/// Integration-level behaviour of the `ReaderViewModel` ↔ `FavoritesStore`
/// / `PageBookmarksStore` wiring. `currentSourceURL` is `private(set)`, so
/// without going through the full `load(url:)` pipeline we can only exercise
/// the "no source" guard paths — which is what users would hit when the app
/// is opened with no book.
@MainActor
struct ReaderViewModelBookmarksTests {

    @Test func currentPositionKeyIsNilWithoutSource() {
        let vm = ReaderViewModel()
        #expect(vm.currentPositionKey == nil)
    }

    @Test func isCurrentBookFavoriteIsFalseWithoutSource() {
        let vm = ReaderViewModel()
        #expect(vm.isCurrentBookFavorite == false)
    }

    @Test func toggleFavoriteIsNoOpWithoutSource() {
        let vm = ReaderViewModel()
        let before = vm.favorites.favorites.count
        vm.toggleFavoriteForCurrentBook()
        #expect(vm.favorites.favorites.count == before)
    }

    @Test func zipInZipFavoriteStoresOuterArchiveAndInnerPath() throws {
        UserDefaults.standard.removeObject(forKey: FavoritesStore.favoritesKey)
        defer { UserDefaults.standard.removeObject(forKey: FavoritesStore.favoritesKey) }

        let outerDir = try Fixture.makeTempDir()
        let tempRoot = try Fixture.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: outerDir)
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let outer = outerDir.appendingPathComponent("series.cbz")
        _ = try Fixture.writeFile(outer)
        let innerVolume = tempRoot.appendingPathComponent("Vol02", isDirectory: true)
        try FileManager.default.createDirectory(at: innerVolume, withIntermediateDirectories: true)

        let vm = ReaderViewModel()
        vm.openedSourceURL = outer
        vm.tempDir.url = tempRoot
        vm.currentSourceURL = innerVolume

        vm.toggleFavoriteForCurrentBook()

        guard let favorite = vm.favorites.favorites.first else {
            Issue.record("expected zip-in-zip favorite to be stored")
            return
        }
        #expect(favorite.path == outer.path)
        #expect(favorite.innerPath == "Vol02")
        #expect(vm.isCurrentBookFavorite)
    }

    @Test func isCurrentPageBookmarkedIsFalseWithoutSource() {
        let vm = ReaderViewModel()
        #expect(vm.isCurrentPageBookmarked == false)
    }

    @Test func toggleCurrentPageBookmarkIsNoOpWithoutSource() {
        let vm = ReaderViewModel()
        let beforeKeys = vm.pageBookmarks.pageBookmarksByBook.keys.count
        vm.toggleCurrentPageBookmark()
        #expect(vm.pageBookmarks.pageBookmarksByBook.keys.count == beforeKeys)
    }

    @Test func currentBookPageBookmarksIsEmptyWithoutSource() {
        let vm = ReaderViewModel()
        #expect(vm.currentBookPageBookmarks.isEmpty)
        #expect(vm.hasPageBookmarks == false)
    }

    @Test func bookmarkNavigationIsDisabledWithoutSource() {
        let vm = ReaderViewModel()
        #expect(vm.canGoNextBookmark == false)
        #expect(vm.canGoPreviousBookmark == false)

        // Must not crash or mutate state either.
        vm.jumpToNextBookmark()
        vm.jumpToPreviousBookmark()
        #expect(vm.currentPageIndex == 0)
    }
}
