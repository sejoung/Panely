import Testing
import Foundation
import AppKit
@testable import Panely

/// Covers the black-screen-on-book-switch fix in vertical mode and its
/// continue-reading safety net.
///
/// Switching books in vertical mode used to leave the *previous* book's strip
/// (and its `ImageStackView` frames) on screen through the new book's up-front
/// dimension fetch. The restored-position scroll-sync then ran against those
/// stale frames and was suppressed when the real strip was built, leaving the
/// viewer scrolled to a frame that no longer existed — a black gap.
///
/// The fix has two parts, both exercised here:
///   1. `prepareForBookSwitch()` drops the outgoing strip at load start.
///   2. `setCurrentPageFromScroll` ignores scroll-driven indices while
///      `isLoading`, so the transient empty strip (which reports page 0) can't
///      overwrite the book's saved continue-reading position via the
///      `currentPageIndex` didSet.
@MainActor
@Suite(.serialized)
struct ReaderViewModelBookSwitchStripResetTests {

    // MARK: - prepareForBookSwitch clears the displayed strip

    @Test func prepareForBookSwitchClearsStaleStrip() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .vertical
        vm.currentImages = (0..<10).map { _ in NSImage(size: NSSize(width: 1000, height: 1500)) }
        vm.pageDimensions = Array(repeating: CGSize(width: 1000, height: 1500), count: 10)

        vm.imageLoader.prepareForBookSwitch()

        #expect(vm.currentImages.isEmpty)
        #expect(vm.pageDimensions.isEmpty)
    }

    /// The mechanism behind the black gap: an emptied strip has no frame for
    /// the restored page, so the premature scroll-sync finds nothing to scroll
    /// to (instead of landing on a stale frame). Once the empty strip is
    /// installed, `frame(forPageAt:)` returns nil for every index.
    @Test func clearedStripHasNoFrameForRestoredPage() {
        let stack = ImageStackView(frame: .zero)
        let images = (0..<8).map { _ in NSImage(size: NSSize(width: 1000, height: 1500)) }
        stack.setImages(images, axis: .vertical)
        #expect(stack.frame(forPageAt: 5) != nil) // mid-book frame exists while populated

        stack.setImages([], axis: .vertical) // mirrors prepareForBookSwitch → empty strip
        #expect(stack.frame(forPageAt: 5) == nil)
        #expect(stack.frame(forPageAt: 0) == nil)
    }

    // MARK: - setCurrentPageFromScroll guards the saved position while loading

    @Test func scrollDrivenIndexIsIgnoredWhileLoading() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .vertical
        vm.currentPageIndex = 6

        vm.isLoading = true
        vm.setCurrentPageFromScroll(0) // transient empty-strip callback

        #expect(vm.currentPageIndex == 6) // restored position untouched
    }

    @Test func scrollDrivenIndexAppliesAgainOnceLoadingFinishes() {
        let vm = makeViewModel(pageCount: 10)
        vm.layout = .vertical
        vm.currentPageIndex = 6

        vm.isLoading = true
        vm.setCurrentPageFromScroll(0)
        #expect(vm.currentPageIndex == 6)

        vm.isLoading = false
        vm.setCurrentPageFromScroll(3) // normal scrolling resumes
        #expect(vm.currentPageIndex == 3)
    }

    // MARK: - continue-reading position is not corrupted across a switch

    /// End-to-end intent: a transient scroll-to-0 during a load must not write
    /// 0 over the book's persisted continue-reading position. Proven through
    /// the real position store, not just the in-memory index.
    @Test func transientLoadScrollDoesNotOverwriteSavedPosition() {
        let defaults = InMemoryKeyValueStore()
        let url = URL(fileURLWithPath: "/tmp/switch-test-\(UUID()).cbz")

        let vm = makeViewModel(pageCount: 10, defaults: defaults)
        vm.layout = .vertical
        vm.currentSourceURL = url
        vm.currentPageIndex = 7
        vm.flushPositionImmediately()
        #expect(vm.restoredIndex(for: url) == 7)

        // Simulate the load window: strip is being rebuilt and emits a 0.
        vm.isLoading = true
        vm.setCurrentPageFromScroll(0)
        vm.flushPositionImmediately()

        // Both the live index and the persisted value must still be 7.
        #expect(vm.currentPageIndex == 7)
        #expect(vm.restoredIndex(for: url) == 7)

        // A fresh VM restoring from the same store proves nothing 0'd it out.
        let vm2 = makeTestViewModel(keyValueStore: defaults)
        vm2.openedSourceURL = url
        #expect(vm2.restoredIndex(for: url) == 7)
    }

    // MARK: - helpers

    private func makeViewModel(
        pageCount: Int,
        defaults: InMemoryKeyValueStore = InMemoryKeyValueStore()
    ) -> ReaderViewModel {
        let vm = makeTestViewModel(keyValueStore: defaults)
        vm.source = ComicSource(title: "Test", pages: Fixture.makeImagePages(count: pageCount))
        return vm
    }
}
