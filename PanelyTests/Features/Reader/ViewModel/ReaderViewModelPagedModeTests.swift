import Testing
import Foundation
@testable import Panely

/// Behaviors that apply when `ReaderViewModel.layout` is `.single` or `.double`.
/// Vertical-specific behavior lives in `ReaderViewModelVerticalModeTests`.
@MainActor
struct ReaderViewModelPagedModeTests {

    // MARK: visiblePages

    @Test func visiblePagesReturnsExactlyOnePageInSingleLayout() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single
        vm.currentPageIndex = 3

        #expect(vm.visiblePages.count == 1)
        #expect(vm.visiblePages.first?.displayName == "p3.png")
    }

    @Test func visiblePagesReturnsTwoConsecutivePagesInDoubleLayout() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .double
        vm.currentPageIndex = 4

        #expect(vm.visiblePages.map(\.displayName) == ["p4.png", "p5.png"])
    }

    @Test func visiblePagesClampsAtEndForDoubleLayoutWhenOnlyOneRemains() {
        let vm = makeViewModel(pageCount: 5)
        vm.layout = .double
        vm.currentPageIndex = 4 // last page, no partner

        #expect(vm.visiblePages.count == 1)
        #expect(vm.visiblePages.first?.displayName == "p4.png")
    }

    @Test func visiblePagesIsEmptyWhenSourceHasNoPages() {
        let vm = makeTestViewModel()
        vm.layout = .single

        #expect(vm.visiblePages.isEmpty)
    }

    // MARK: setCurrentPageFromScroll — must be a no-op in paged modes

    @Test func setCurrentPageFromScrollIgnoredInSingleLayout() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single
        vm.currentPageIndex = 0

        vm.setCurrentPageFromScroll(7)
        #expect(vm.currentPageIndex == 0)
    }

    @Test func setCurrentPageFromScrollIgnoredInDoubleLayout() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .double
        vm.currentPageIndex = 2

        vm.setCurrentPageFromScroll(8)
        #expect(vm.currentPageIndex == 2)
    }

    // MARK: toggleLayout side effects in paged modes

    @Test func togglingFromSingleToDoublePreservesFitMode() {
        let vm = makeTestViewModel()
        vm.layout = .single
        vm.fitMode = .fitScreen

        vm.toggleLayout()

        #expect(vm.layout == .double)
        #expect(vm.fitMode == .fitScreen) // paged → paged: fitMode untouched
    }

    // MARK: navigationStep mirrors PageLayout

    @Test func navigationStepIsOneInSingleLayout() {
        let vm = makeTestViewModel()
        vm.layout = .single
        #expect(vm.navigationStep == 1)
    }

    @Test func navigationStepIsTwoInDoubleLayout() {
        let vm = makeTestViewModel()
        vm.layout = .double
        #expect(vm.navigationStep == 2)
    }

    // MARK: reading direction is honored in paged modes

    @Test func toggleDirectionFlipsInSingleLayout() {
        let vm = makeTestViewModel()
        vm.layout = .single
        vm.direction = .leftToRight

        vm.toggleDirection()
        #expect(vm.direction == .rightToLeft)

        vm.toggleDirection()
        #expect(vm.direction == .leftToRight)
    }

    @Test func toggleDirectionFlipsInDoubleLayout() {
        let vm = makeTestViewModel()
        vm.layout = .double
        vm.direction = .leftToRight

        vm.toggleDirection()
        #expect(vm.direction == .rightToLeft)
    }

    @Test func effectiveDirectionMatchesUserPreferenceInPagedModes() {
        let vm = makeTestViewModel()

        vm.layout = .single
        vm.direction = .rightToLeft
        #expect(vm.effectiveDirection == .rightToLeft)

        vm.layout = .double
        vm.direction = .leftToRight
        #expect(vm.effectiveDirection == .leftToRight)
    }

    // MARK: helpers

    private func makeViewModel(pageCount: Int) -> ReaderViewModel {
        let vm = makeTestViewModel()
        vm.source = ComicSource(title: "Test", pages: Fixture.makeImagePages(count: pageCount))
        return vm
    }
}
