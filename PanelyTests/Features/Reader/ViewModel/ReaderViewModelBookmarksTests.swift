import Testing
import Foundation
@testable import Panely

/// Integration-level behaviour of the `ReaderViewModel` ↔ `BookmarksStore`
/// wiring. `currentSourceURL` is `private(set)`, so without going through
/// the full `load(url:)` pipeline we can only exercise the "no source" guard
/// paths — which is what users would hit when the app is opened with no book.
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
        let before = vm.bookmarks.favorites.count
        vm.toggleFavoriteForCurrentBook()
        #expect(vm.bookmarks.favorites.count == before)
    }

    @Test func isCurrentPageBookmarkedIsFalseWithoutSource() {
        let vm = ReaderViewModel()
        #expect(vm.isCurrentPageBookmarked == false)
    }

    @Test func toggleCurrentPageBookmarkIsNoOpWithoutSource() {
        let vm = ReaderViewModel()
        let beforeKeys = vm.bookmarks.pageBookmarksByBook.keys.count
        vm.toggleCurrentPageBookmark()
        #expect(vm.bookmarks.pageBookmarksByBook.keys.count == beforeKeys)
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
