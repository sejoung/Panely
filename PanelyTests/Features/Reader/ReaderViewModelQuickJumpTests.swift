import Testing
import Foundation
@testable import Panely

/// Covers the 1-indexed page-number helpers that back `QuickJumpField` and
/// `promptJumpToPage` in `PanelyApp`.
@MainActor
struct ReaderViewModelQuickJumpTests {

    // MARK: currentPageNumber / currentPageRangeEndNumber

    @Test func currentPageNumberIsOneIndexed() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single
        vm.currentPageIndex = 0
        #expect(vm.currentPageNumber == 1)

        vm.currentPageIndex = 9
        #expect(vm.currentPageNumber == 10)
    }

    @Test func currentPageNumberIsZeroWithoutSource() {
        let vm = ReaderViewModel()
        #expect(vm.currentPageNumber == 0)
    }

    @Test func rangeEndEqualsStartInSinglePage() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single
        vm.currentPageIndex = 3
        #expect(vm.currentPageRangeEndNumber == 4)
    }

    @Test func rangeEndIsStartPlusOneInDoublePage() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .double
        vm.currentPageIndex = 4
        // First page 5, last page 6.
        #expect(vm.currentPageRangeEndNumber == 6)
    }

    @Test func rangeEndClampsToLastPageInDoubleAtEnd() {
        let vm = makeViewModel(pageCount: 5)
        vm.layout = .double
        vm.currentPageIndex = 4 // Last page, no partner.
        #expect(vm.currentPageRangeEndNumber == 5)
    }

    // MARK: jump(toPageNumber:) — input clamping

    @Test func jumpToPageNumberClampsNegativeAndZeroToFirstPage() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single
        vm.currentPageIndex = 5

        vm.jump(toPageNumber: 0)
        #expect(vm.currentPageIndex == 0)

        vm.currentPageIndex = 5
        vm.jump(toPageNumber: -100)
        #expect(vm.currentPageIndex == 0)
    }

    @Test func jumpToPageNumberClampsBeyondLastPage() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single
        vm.currentPageIndex = 0

        vm.jump(toPageNumber: 100)
        #expect(vm.currentPageIndex == 9)
    }

    @Test func jumpToPageNumberConvertsToZeroIndexed() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single

        vm.jump(toPageNumber: 7)
        #expect(vm.currentPageIndex == 6)
    }

    @Test func jumpToPageNumberSnapsToStepInDoubleMode() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .double

        // Page 4 (index 3) rounds down to the step boundary — index 2.
        vm.jump(toPageNumber: 4)
        #expect(vm.currentPageIndex == 2)

        // Page 5 (index 4) is already on a boundary in step=2.
        vm.jump(toPageNumber: 5)
        #expect(vm.currentPageIndex == 4)
    }

    @Test func jumpToPageNumberIsNoOpWithoutSource() {
        let vm = ReaderViewModel()
        vm.jump(toPageNumber: 5)
        #expect(vm.currentPageIndex == 0)
    }

    // MARK: helpers

    private func makeViewModel(pageCount: Int) -> ReaderViewModel {
        let vm = ReaderViewModel()
        vm.source = ComicSource(title: "Test", pages: makePages(pageCount))
        return vm
    }

    private func makePages(_ count: Int) -> [ComicPage] {
        (0..<count).map { i in
            ComicPage(
                source: .file(URL(fileURLWithPath: "/p\(i).jpg")),
                displayName: "p\(i).jpg"
            )
        }
    }
}
