import Testing
import Foundation
import AppKit
@testable import Panely

/// Coverage for `AppKitScrollerCoordinator`'s observer attachment semantics.
/// The frame observer's effects are hard to assert without a fully-laid-out
/// scroll view (it calls `applyFit`, which needs nonzero viewport / doc
/// sizes); the bounds observer's effects are directly observable via the
/// `onPageIndexChanged` / `onVisibleRangeChanged` callbacks, so most of the
/// suite drives that path.
@MainActor
struct AppKitScrollerCoordinatorTests {

    // MARK: - attachBoundsObserver: callback firing

    @Test func boundsChangePostsPageAndRangeCallbacksInVerticalLayout() {
        let setup = makeWiredCoordinator(layout: .vertical, pageCount: 5)

        var pageEvents: [Int] = []
        var rangeEvents: [Range<Int>] = []
        setup.coordinator.onPageIndexChanged = { pageEvents.append($0) }
        setup.coordinator.onVisibleRangeChanged = { rangeEvents.append($0) }

        setup.coordinator.attachBoundsObserver(to: setup.scrollView)
        // Scroll the clip view to the second page so the observer sees a real
        // bounds change — without this the contentView's bounds origin stays
        // at (0,0) and the notification's payload is uninteresting.
        scrollTo(page: 1, in: setup)

        #expect(pageEvents.last == 1, "page index callback should fire with the new center page")
        #expect(rangeEvents.last?.contains(1) == true, "visible-range callback should include the visible page")
    }

    @Test func boundsChangeIsNoOpForPagedLayout() {
        // Horizontal/paged mode never relies on the bounds observer — the
        // viewer drives navigation explicitly. Posting a bounds change must
        // not fire either callback so paged-mode listeners aren't surprised.
        let setup = makeWiredCoordinator(layout: .single, pageCount: 5)

        var pageFired = false
        var rangeFired = false
        setup.coordinator.onPageIndexChanged = { _ in pageFired = true }
        setup.coordinator.onVisibleRangeChanged = { _ in rangeFired = true }

        setup.coordinator.attachBoundsObserver(to: setup.scrollView)
        scrollTo(page: 1, in: setup)

        #expect(pageFired == false)
        #expect(rangeFired == false)
    }

    @Test func programmaticScrollSuppressesPageIndexCallbackButNotRange() {
        // `updateNSView` sets `isProgrammaticallyScrolling` while it sync-
        // scrolls to a restored position so the model doesn't bounce its own
        // assignment back through `setCurrentPageFromScroll`. Visible-range
        // callback must still fire so lazy loading kicks in for the newly-
        // revealed pages.
        let setup = makeWiredCoordinator(layout: .vertical, pageCount: 5)

        var pageEvents: [Int] = []
        var rangeEvents: [Range<Int>] = []
        setup.coordinator.onPageIndexChanged = { pageEvents.append($0) }
        setup.coordinator.onVisibleRangeChanged = { rangeEvents.append($0) }

        setup.coordinator.attachBoundsObserver(to: setup.scrollView)
        setup.coordinator.isProgrammaticallyScrolling = true
        scrollTo(page: 2, in: setup)

        #expect(pageEvents.isEmpty, "page index callback must be suppressed during programmatic scroll")
        #expect(rangeEvents.isEmpty == false, "visible-range callback must still fire so lazy load proceeds")
    }

    // MARK: - attachBoundsObserver: dedup

    @Test func samePageNotificationIsDedupedAfterFirstFire() {
        // The bounds observer's first scroll reports the new page; subsequent
        // bounds changes that don't change which page is centered must not
        // re-fire the page-index callback. Without dedup, mouse wheel ticks
        // within a single page would spam the model.
        let setup = makeWiredCoordinator(layout: .vertical, pageCount: 5)

        var pageEventCount = 0
        setup.coordinator.onPageIndexChanged = { _ in pageEventCount += 1 }
        setup.coordinator.attachBoundsObserver(to: setup.scrollView)

        scrollTo(page: 1, in: setup)
        scrollTo(page: 1, in: setup) // Same page — must not refire.
        scrollTo(page: 1, in: setup)

        #expect(pageEventCount == 1)
    }

    // MARK: - Re-attach safety (the real reason these methods exist)

    @Test func reAttachingBoundsObserverDoesNotDoubleFireCallbacks() {
        // SwiftUI is free to recreate the representable on tick, which means
        // `attachBoundsObserver` can be called more than once on the same
        // coordinator. The contract is that the previous observer is removed
        // before the new one is added — otherwise every scroll tick would
        // double up callbacks and the model would oscillate.
        let setup = makeWiredCoordinator(layout: .vertical, pageCount: 5)

        var pageEventCount = 0
        setup.coordinator.onPageIndexChanged = { _ in pageEventCount += 1 }

        setup.coordinator.attachBoundsObserver(to: setup.scrollView)
        setup.coordinator.attachBoundsObserver(to: setup.scrollView) // Re-attach.
        scrollTo(page: 1, in: setup)

        #expect(pageEventCount == 1, "re-attaching must remove the previous observer; otherwise the callback fires twice")
    }

    @Test func reAttachingFrameObserverDoesNotLeakAfterDeinit() {
        // Same lifecycle contract for the frame observer: re-attaching must
        // remove the prior token, and the final token must be released on
        // deinit. Without the cleanup the Coordinator (and its captured
        // weak refs) would be kept alive by NotificationCenter.
        weak var weakCoordinator: AppKitScrollerCoordinator?
        do {
            let setup = makeWiredCoordinator(layout: .single, pageCount: 1)
            let coordinator = setup.coordinator
            coordinator.attachFrameObserver(to: setup.scrollView)
            coordinator.attachFrameObserver(to: setup.scrollView) // Re-attach.
            weakCoordinator = coordinator
            #expect(weakCoordinator != nil)
        }
        #expect(weakCoordinator == nil)
    }

    // MARK: - Helpers

    private struct WiredCoordinator {
        let scrollView: NSScrollView
        let stack: ImageStackView
        let coordinator: AppKitScrollerCoordinator
    }

    /// Build a scroll view + ImageStackView + coordinator triple ready for
    /// bounds-observer testing. `pageCount` placeholder images give the
    /// stack a real frame layout so `pageIndex(forViewportY:)` returns
    /// meaningful values.
    private func makeWiredCoordinator(layout: PageLayout, pageCount: Int) -> WiredCoordinator {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.contentView = CenteringClipView()
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.hasVerticalScroller = true
        scrollView.allowsMagnification = true

        let stack = ImageStackView()
        let pageSize = CGSize(width: 400, height: 600)
        let images = (0..<pageCount).map { _ in
            ReaderImageLoader.makePlaceholder(size: pageSize)
        }
        let axis: ImageStackView.Axis = layout.isContinuous ? .vertical : .horizontal
        stack.setImages(images, axis: axis)
        scrollView.documentView = stack
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        coordinator.scrollView = scrollView
        coordinator.lastLayout = layout

        return WiredCoordinator(scrollView: scrollView, stack: stack, coordinator: coordinator)
    }

    /// Scroll the clip view so the requested page sits at the top of the
    /// viewport. Triggers `NSView.boundsDidChangeNotification` synchronously
    /// because the clip view has `postsBoundsChangedNotifications = true`.
    private func scrollTo(page: Int, in setup: WiredCoordinator) {
        guard let frame = setup.stack.frame(forPageAt: page) else { return }
        setup.scrollView.contentView.scroll(to: NSPoint(x: 0, y: frame.minY))
        setup.scrollView.reflectScrolledClipView(setup.scrollView.contentView)
    }
}
