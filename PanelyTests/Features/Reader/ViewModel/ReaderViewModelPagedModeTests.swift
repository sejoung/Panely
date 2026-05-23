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
        #expect(vm.visiblePages.first?.displayName == "p3.jpg")
    }

    @Test func visiblePagesReturnsTwoConsecutivePagesInDoubleLayout() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .double
        vm.currentPageIndex = 4

        #expect(vm.visiblePages.map(\.displayName) == ["p4.jpg", "p5.jpg"])
    }

    @Test func visiblePagesClampsAtEndForDoubleLayoutWhenOnlyOneRemains() {
        let vm = makeViewModel(pageCount: 5)
        vm.layout = .double
        vm.currentPageIndex = 4 // last page, no partner

        #expect(vm.visiblePages.count == 1)
        #expect(vm.visiblePages.first?.displayName == "p4.jpg")
    }

    @Test func visiblePagesIsEmptyWhenSourceHasNoPages() {
        let vm = ReaderViewModel()
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
        let vm = ReaderViewModel()
        vm.layout = .single
        vm.fitMode = .fitScreen

        vm.toggleLayout()

        #expect(vm.layout == .double)
        #expect(vm.fitMode == .fitScreen) // paged → paged: fitMode untouched
    }

    // MARK: navigationStep mirrors PageLayout

    @Test func navigationStepIsOneInSingleLayout() {
        let vm = ReaderViewModel()
        vm.layout = .single
        #expect(vm.navigationStep == 1)
    }

    @Test func navigationStepIsTwoInDoubleLayout() {
        let vm = ReaderViewModel()
        vm.layout = .double
        #expect(vm.navigationStep == 2)
    }

    // MARK: reading direction is honored in paged modes

    @Test func toggleDirectionFlipsInSingleLayout() {
        let vm = ReaderViewModel()
        vm.layout = .single
        vm.direction = .leftToRight

        vm.toggleDirection()
        #expect(vm.direction == .rightToLeft)

        vm.toggleDirection()
        #expect(vm.direction == .leftToRight)
    }

    @Test func toggleDirectionFlipsInDoubleLayout() {
        let vm = ReaderViewModel()
        vm.layout = .double
        vm.direction = .leftToRight

        vm.toggleDirection()
        #expect(vm.direction == .rightToLeft)
    }

    @Test func effectiveDirectionMatchesUserPreferenceInPagedModes() {
        let vm = ReaderViewModel()

        vm.layout = .single
        vm.direction = .rightToLeft
        #expect(vm.effectiveDirection == .rightToLeft)

        vm.layout = .double
        vm.direction = .leftToRight
        #expect(vm.effectiveDirection == .leftToRight)
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
