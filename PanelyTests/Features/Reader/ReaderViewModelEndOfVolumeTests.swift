import Testing
import Foundation
@testable import Panely

/// Covers the end-of-volume card visibility logic and its restart helper.
/// Volume-advance itself is exercised in `ReaderViewModelLibraryTests` —
/// here we only assert the card surfaces at the right moment.
@MainActor
struct ReaderViewModelEndOfVolumeTests {

    // MARK: isAtLastPage

    @Test func isAtLastPageFalseWhenNoSource() {
        let vm = ReaderViewModel()
        #expect(vm.isAtLastPage == false)
    }

    @Test func isAtLastPageFalseInMiddle() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single
        vm.currentPageIndex = 4
        #expect(vm.isAtLastPage == false)
    }

    @Test func isAtLastPageTrueOnFinalPageSingleLayout() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single
        vm.currentPageIndex = 9
        #expect(vm.isAtLastPage == true)
    }

    @Test func isAtLastPageTrueOnFinalSpreadDoubleLayout() {
        // navigationStep == 2; idx 8 + 2 == 10 == pageCount.
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .double
        vm.currentPageIndex = 8
        #expect(vm.isAtLastPage == true)
    }

    @Test func isAtLastPageTrueOnTrailingOddPageDoubleLayout() {
        // 11-page book in double layout: last spread is idx 10 alone.
        let vm = makeViewModel(pageCount: 11)
        vm.layout = .double
        vm.currentPageIndex = 10
        #expect(vm.isAtLastPage == true)
    }

    // MARK: showsEndOfVolumeCard

    @Test func cardHiddenWithoutNextSibling() {
        let vm = makeViewModel(pageCount: 5)
        vm.layout = .single
        vm.currentPageIndex = 4
        // No siblings → standalone book → no card even at last page.
        vm.siblings = []
        #expect(vm.showsEndOfVolumeCard == false)
    }

    @Test func cardHiddenOnLastSiblingInSeries() {
        let vm = makeViewModel(pageCount: 5)
        vm.layout = .single
        vm.currentPageIndex = 4

        let url1 = URL(fileURLWithPath: "/series/Vol01.cbz")
        let url2 = URL(fileURLWithPath: "/series/Vol02.cbz")
        vm.siblings = [url1, url2]
        vm.currentSourceURL = url2
        // At final volume → no next → no card.
        #expect(vm.showsEndOfVolumeCard == false)
    }

    @Test func cardShownAtLastPageWhenNextSiblingExists() {
        let vm = makeViewModel(pageCount: 5)
        vm.layout = .single
        vm.currentPageIndex = 4

        let url1 = URL(fileURLWithPath: "/series/Vol01.cbz")
        let url2 = URL(fileURLWithPath: "/series/Vol02.cbz")
        vm.siblings = [url1, url2]
        vm.currentSourceURL = url1
        #expect(vm.showsEndOfVolumeCard == true)
    }

    @Test func cardHiddenInMiddleEvenWithNextSibling() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single
        vm.currentPageIndex = 3

        let url1 = URL(fileURLWithPath: "/series/Vol01.cbz")
        let url2 = URL(fileURLWithPath: "/series/Vol02.cbz")
        vm.siblings = [url1, url2]
        vm.currentSourceURL = url1
        #expect(vm.showsEndOfVolumeCard == false)
    }

    // MARK: nextVolumeDisplayName

    @Test func nextVolumeDisplayNameStripsExtension() {
        let vm = makeViewModel(pageCount: 5)
        vm.siblings = [
            URL(fileURLWithPath: "/series/Vol01.cbz"),
            URL(fileURLWithPath: "/series/Vol02 - The Long Trail.cbz")
        ]
        vm.currentSourceURL = vm.siblings[0]
        #expect(vm.nextVolumeDisplayName == "Vol02 - The Long Trail")
    }

    @Test func nextVolumeDisplayNameNilOnLastSibling() {
        let vm = makeViewModel(pageCount: 5)
        vm.siblings = [
            URL(fileURLWithPath: "/series/Vol01.cbz"),
            URL(fileURLWithPath: "/series/Vol02.cbz")
        ]
        vm.currentSourceURL = vm.siblings[1]
        #expect(vm.nextVolumeDisplayName == nil)
    }

    // MARK: advanceForward dispatch

    @Test func advanceForwardPagesWhenNotAtLastPage() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single
        vm.currentPageIndex = 3

        vm.advanceForward()
        // Card not showing → falls through to next() → page advances by step.
        #expect(vm.currentPageIndex == 4)
    }

    @Test func advanceForwardNoOpsAtLastPageWithoutNextSibling() {
        let vm = makeViewModel(pageCount: 5)
        vm.layout = .single
        vm.currentPageIndex = 4
        vm.siblings = []

        vm.advanceForward()
        // No card → next() guards at end of book → no-op.
        #expect(vm.currentPageIndex == 4)
    }

    @Test func advanceForwardDoesNotPageWhenCardIsShowing() {
        let vm = makeViewModel(pageCount: 5)
        vm.layout = .single
        vm.currentPageIndex = 4

        let url1 = URL(fileURLWithPath: "/series/Vol01.cbz")
        let url2 = URL(fileURLWithPath: "/series/Vol02.cbz")
        vm.siblings = [url1, url2]
        vm.currentSourceURL = url1

        // Card visible → forward dispatches to nextVolume() (async file load
        // we can't observe synchronously here). The contract this test
        // protects is: it must not also bump currentPageIndex via next(),
        // which would mean we ran both branches.
        vm.advanceForward()
        #expect(vm.currentPageIndex == 4)
    }

    // MARK: restartCurrentVolume

    @Test func restartJumpsToFirstPage() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single
        vm.currentPageIndex = 9

        vm.restartCurrentVolume()
        #expect(vm.currentPageIndex == 0)
    }

    @Test func restartIsNoOpWhenNoSource() {
        let vm = ReaderViewModel()
        vm.restartCurrentVolume()
        #expect(vm.currentPageIndex == 0)
    }

    // MARK: showsPreviousVolumeCard / goBackward dispatch

    @Test func prevCardHiddenOnFreshOpenAtPageZero() {
        // Mimics the "loaded into Vol 02 at page 0" case — flag should not
        // be set without explicit user intent, so the card must stay hidden.
        let vm = makeViewModel(pageCount: 5)
        vm.layout = .single
        vm.currentPageIndex = 0
        vm.siblings = [
            URL(fileURLWithPath: "/series/Vol01.cbz"),
            URL(fileURLWithPath: "/series/Vol02.cbz")
        ]
        vm.currentSourceURL = vm.siblings[1]

        #expect(vm.showsPreviousVolumeCard == false)
    }

    @Test func goBackwardAtPageZeroFirstPressArmsCueAndDoesNotLoad() {
        let vm = makeViewModel(pageCount: 5)
        vm.layout = .single
        vm.currentPageIndex = 0
        vm.siblings = [
            URL(fileURLWithPath: "/series/Vol01.cbz"),
            URL(fileURLWithPath: "/series/Vol02.cbz")
        ]
        vm.currentSourceURL = vm.siblings[1]

        vm.goBackward()
        #expect(vm.showsPreviousVolumeCard == true)
        #expect(vm.currentPageIndex == 0)
    }

    @Test func goBackwardAtPageZeroNoOpsWithoutPreviousSibling() {
        let vm = makeViewModel(pageCount: 5)
        vm.layout = .single
        vm.currentPageIndex = 0
        vm.siblings = [URL(fileURLWithPath: "/series/Vol01.cbz")]
        vm.currentSourceURL = vm.siblings[0]

        vm.goBackward()
        #expect(vm.showsPreviousVolumeCard == false)
    }

    @Test func goBackwardLandingOnZeroAutoArmsCue() {
        // User reading forward, scrolls back to page 0 — symmetry with the
        // forward card auto-appearing on reaching the last page.
        let vm = makeViewModel(pageCount: 5)
        vm.layout = .single
        vm.currentPageIndex = 1
        vm.siblings = [
            URL(fileURLWithPath: "/series/Vol01.cbz"),
            URL(fileURLWithPath: "/series/Vol02.cbz")
        ]
        vm.currentSourceURL = vm.siblings[1]

        vm.goBackward()
        #expect(vm.currentPageIndex == 0)
        #expect(vm.showsPreviousVolumeCard == true)
    }

    @Test func goBackwardPagesNormallyAboveZero() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single
        vm.currentPageIndex = 5
        vm.siblings = [
            URL(fileURLWithPath: "/series/Vol01.cbz"),
            URL(fileURLWithPath: "/series/Vol02.cbz")
        ]
        vm.currentSourceURL = vm.siblings[1]

        vm.goBackward()
        #expect(vm.currentPageIndex == 4)
        #expect(vm.showsPreviousVolumeCard == false)
    }

    @Test func anyPageChangeClearsThePreviousVolumeCue() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .single
        vm.currentPageIndex = 0
        vm.siblings = [
            URL(fileURLWithPath: "/series/Vol01.cbz"),
            URL(fileURLWithPath: "/series/Vol02.cbz")
        ]
        vm.currentSourceURL = vm.siblings[1]

        vm.goBackward()
        #expect(vm.showsPreviousVolumeCard == true)

        vm.jump(to: 3)
        #expect(vm.showsPreviousVolumeCard == false)
    }

    @Test func previousVolumeDisplayNameStripsExtension() {
        let vm = makeViewModel(pageCount: 5)
        vm.siblings = [
            URL(fileURLWithPath: "/series/Vol01 - The Beginning.cbz"),
            URL(fileURLWithPath: "/series/Vol02.cbz")
        ]
        vm.currentSourceURL = vm.siblings[1]
        #expect(vm.previousVolumeDisplayName == "Vol01 - The Beginning")
    }

    @Test func previousVolumeDisplayNameNilOnFirstSibling() {
        let vm = makeViewModel(pageCount: 5)
        vm.siblings = [
            URL(fileURLWithPath: "/series/Vol01.cbz"),
            URL(fileURLWithPath: "/series/Vol02.cbz")
        ]
        vm.currentSourceURL = vm.siblings[0]
        #expect(vm.previousVolumeDisplayName == nil)
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
