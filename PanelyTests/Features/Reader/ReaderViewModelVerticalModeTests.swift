import Testing
import Foundation
@testable import Panely

/// Behaviors that apply when `ReaderViewModel.layout == .vertical` (webtoon
/// strip). Paged behaviors live in `ReaderViewModelPagedModeTests`.
@MainActor
struct ReaderViewModelVerticalModeTests {

    // MARK: visiblePages — vertical loads the whole strip

    @Test func visiblePagesReturnsAllPagesInVerticalLayout() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .vertical
        vm.currentPageIndex = 5 // index does not narrow the slice in vertical

        #expect(vm.visiblePages.count == 10)
        #expect(vm.visiblePages.map(\.displayName) == (0..<10).map { "p\($0).jpg" })
    }

    @Test func visiblePagesIsEmptyWhenSourceHasNoPagesInVertical() {
        let vm = ReaderViewModel()
        vm.layout = .vertical

        #expect(vm.visiblePages.isEmpty)
    }

    // MARK: setCurrentPageFromScroll — only effective path

    @Test func setCurrentPageFromScrollUpdatesIndexInVerticalLayout() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .vertical
        vm.currentPageIndex = 0

        vm.setCurrentPageFromScroll(7)
        #expect(vm.currentPageIndex == 7)
    }

    @Test func setCurrentPageFromScrollIgnoresOutOfBoundsIndex() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .vertical
        vm.currentPageIndex = 4

        vm.setCurrentPageFromScroll(99)
        #expect(vm.currentPageIndex == 4)

        vm.setCurrentPageFromScroll(-1)
        #expect(vm.currentPageIndex == 4)
    }

    @Test func setCurrentPageFromScrollIsIdempotentForSameIndex() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .vertical
        vm.currentPageIndex = 5

        vm.setCurrentPageFromScroll(5)
        #expect(vm.currentPageIndex == 5)
    }

    // MARK: toggleLayout side effects when entering vertical

    @Test func togglingIntoVerticalForcesFitWidth() {
        let vm = ReaderViewModel()
        vm.layout = .double
        vm.fitMode = .fitScreen

        vm.toggleLayout() // .double → .vertical

        #expect(vm.layout == .vertical)
        #expect(vm.fitMode == .fitWidth)
    }

    @Test func togglingFromSingleSkipsVerticalFitChange() {
        let vm = ReaderViewModel()
        vm.layout = .single
        vm.fitMode = .fitScreen

        vm.toggleLayout() // .single → .double, NOT vertical

        #expect(vm.layout == .double)
        #expect(vm.fitMode == .fitScreen) // didn't enter vertical
    }

    @Test func togglingOutOfVerticalDoesNotResetFitMode() {
        let vm = ReaderViewModel()
        vm.layout = .vertical
        vm.fitMode = .fitWidth

        vm.toggleLayout() // .vertical → .single

        #expect(vm.layout == .single)
        #expect(vm.fitMode == .fitWidth) // we don't undo on the way out
    }

    // MARK: navigationStep stays at 1 (vertical advances per-image)

    @Test func navigationStepIsOneInVerticalLayout() {
        let vm = ReaderViewModel()
        vm.layout = .vertical
        #expect(vm.navigationStep == 1)
    }

    // MARK: reading direction has no meaning in vertical (top-to-bottom strip)

    @Test func toggleDirectionIsNoOpInVerticalLayout() {
        let vm = ReaderViewModel()
        vm.layout = .vertical
        vm.direction = .leftToRight

        vm.toggleDirection()
        #expect(vm.direction == .leftToRight) // unchanged
    }

    @Test func effectiveDirectionIsLTRInVerticalEvenIfUserPrefIsRTL() {
        let vm = ReaderViewModel()
        vm.direction = .rightToLeft
        vm.layout = .vertical

        #expect(vm.effectiveDirection == .leftToRight)
    }

    @Test func togglingOutOfVerticalRestoresUserDirectionPreference() {
        let vm = ReaderViewModel()
        vm.direction = .rightToLeft
        vm.layout = .vertical

        // While vertical, effective direction is LTR
        #expect(vm.effectiveDirection == .leftToRight)

        // Exit vertical → user's saved RTL preference returns to navigation
        vm.toggleLayout() // .vertical → .single
        #expect(vm.effectiveDirection == .rightToLeft)
        #expect(vm.direction == .rightToLeft) // never lost
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
