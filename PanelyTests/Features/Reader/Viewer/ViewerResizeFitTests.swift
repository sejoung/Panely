import Testing
import Foundation
import AppKit
@testable import Panely

@MainActor
struct ViewerResizeFitTests {
    /// When the viewport grows and the user has not manually zoomed, applyFit
    /// should snap magnification to the new fit value so the image keeps filling
    /// the viewport on window/sidebar resize.
    @Test func magnificationFollowsViewportWhenUserHasNotZoomed() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true
        )
        let initialFit = scrollView.magnification

        scrollView.frame = NSRect(x: 0, y: 0, width: 1600, height: 1200)
        scrollView.layoutSubtreeIfNeeded()

        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: false
        )

        let expectedFit = FitCalculator.magnification(
            docSize: doc.frame.size,
            viewport: scrollView.contentSize,
            fitMode: .fitScreen
        )
        #expect(abs(scrollView.magnification - expectedFit) < 0.001)
        #expect(scrollView.magnification > initialFit) // larger viewport ⇒ larger fit
    }

    /// If the user has manually zoomed (magnification ≠ baseMagnification),
    /// resizing the viewport must NOT clobber their zoom. Only baseMagnification
    /// updates so that subsequent reset/double-click toggles use the new fit.
    @Test func userZoomIsPreservedOnResize() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true
        )

        let userZoom: CGFloat = 2.0
        scrollView.magnification = userZoom

        scrollView.frame = NSRect(x: 0, y: 0, width: 1600, height: 1200)
        scrollView.layoutSubtreeIfNeeded()

        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: false
        )

        #expect(abs(scrollView.magnification - userZoom) < 0.001)

        let expectedFit = FitCalculator.magnification(
            docSize: doc.frame.size,
            viewport: scrollView.contentSize,
            fitMode: .fitScreen
        )
        #expect(abs(coordinator.baseMagnification - expectedFit) < 0.001)
    }

    /// Force overrides the userHasZoomed guard — used when a new image loads or
    /// fit mode changes, where we explicitly want to reset to the fit value.
    @Test func forceOverridesUserZoom() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true
        )

        scrollView.magnification = 2.0

        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true
        )

        let expectedFit = FitCalculator.magnification(
            docSize: doc.frame.size,
            viewport: scrollView.contentSize,
            fitMode: .fitScreen
        )
        #expect(abs(scrollView.magnification - expectedFit) < 0.001)
    }

    /// Pressing the fit-mode button is the one path that *must* override the
    /// user's manual zoom — the button literally exists to "apply this fit."
    @Test func fitModeChangeForcesFitReset() {
        #expect(AppKitImageScroller.shouldForceFitReset(
            identityChanged: false,
            fitModeChanged: true,
            layoutChanged: false,
            contentStructureChanged: false
        ))
    }

    /// Opening a new book must NOT override the user's chosen magnification.
    /// If they were reading at 2×, the next book opens at 2×. The non-force
    /// path snaps to the new book's fit only when the user hasn't zoomed.
    @Test func identityChangeAloneDoesNotForceFitReset() {
        #expect(AppKitImageScroller.shouldForceFitReset(
            identityChanged: true,
            fitModeChanged: false,
            layoutChanged: false,
            contentStructureChanged: false
        ) == false)
    }

    /// Switching layout (single ↔ double ↔ vertical) is the user moving the
    /// view, not asking for a fresh fit. If they want fit, they press the
    /// fit button.
    @Test func layoutChangeAloneDoesNotForceFitReset() {
        #expect(AppKitImageScroller.shouldForceFitReset(
            identityChanged: false,
            fitModeChanged: false,
            layoutChanged: true,
            contentStructureChanged: false
        ) == false)
    }

    /// Regression: page-flip in paged mode always reports
    /// `contentStructureChanged = true` (the NSImage array is swapped). It
    /// must not force a refit either — covered for completeness alongside
    /// identity / layout changes.
    @Test func contentStructureChangeAloneDoesNotForceFitReset() {
        #expect(AppKitImageScroller.shouldForceFitReset(
            identityChanged: false,
            fitModeChanged: false,
            layoutChanged: false,
            contentStructureChanged: true
        ) == false)
    }

    /// End-to-end behavior at the `applyFit` level: zoom to 2× on the first
    /// page, then simulate a paged page-flip (new doc-size + non-force call).
    /// Magnification must stay at the user's 2×; only `baseMagnification`
    /// updates so that a later "reset zoom" snaps to the new page's fit.
    @Test func userZoomPersistsAcrossPagedNavigation() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let firstPage = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = firstPage
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        // Initial fit on first page.
        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true
        )

        // User zooms in.
        let userZoom: CGFloat = 2.0
        scrollView.magnification = userZoom

        // Page flip: new page has different dimensions (taller). In production
        // this comes from `setImages` swapping NSImages with different sizes,
        // which `updateNSView` then reports as `contentStructureChanged = true`
        // — i.e. `force: false` because no identity/fit/layout change.
        let secondPage = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 2400))
        scrollView.documentView = secondPage
        scrollView.layoutSubtreeIfNeeded()

        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: false
        )

        // The user's zoom must survive the page flip.
        #expect(abs(scrollView.magnification - userZoom) < 0.001)

        // baseMagnification still tracks the new page's fit so a future
        // reset/double-click lands correctly.
        let expectedFit = FitCalculator.magnification(
            docSize: secondPage.frame.size,
            viewport: scrollView.contentSize,
            fitMode: .fitScreen
        )
        #expect(abs(coordinator.baseMagnification - expectedFit) < 0.001)
    }

    /// Opening a new book at 2× zoom: magnification must carry over. The
    /// new book's fit becomes the baseline (so a future fit-button or
    /// reset-zoom lands correctly), but the user's view doesn't snap.
    @Test func userZoomPersistsAcrossBookOpens() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let firstBook = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = firstBook
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true
        )

        // User zooms in while reading the first book.
        let userZoom: CGFloat = 2.0
        scrollView.magnification = userZoom

        // A new book loads (different first-page geometry).
        let secondBook = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 2000))
        scrollView.documentView = secondBook
        scrollView.layoutSubtreeIfNeeded()

        // New book → identityChanged is the only diff, no longer a force.
        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: false
        )

        #expect(abs(scrollView.magnification - userZoom) < 0.001)
        let newFit = FitCalculator.magnification(
            docSize: secondBook.frame.size,
            viewport: scrollView.contentSize,
            fitMode: .fitScreen
        )
        #expect(abs(coordinator.baseMagnification - newFit) < 0.001)
    }

    /// Switching layout at 2× zoom: same expectation as opening a new book.
    /// User chose to swap layout, not to refit; preserve their magnification.
    @Test func userZoomPersistsAcrossLayoutSwap() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let singlePage = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = singlePage
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true
        )
        scrollView.magnification = 2.0

        // Simulate single → double layout: doc grows wider.
        let doublePage = NSView(frame: NSRect(x: 0, y: 0, width: 2000, height: 1500))
        scrollView.documentView = doublePage
        scrollView.layoutSubtreeIfNeeded()

        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: false
        )

        #expect(abs(scrollView.magnification - 2.0) < 0.001)
    }

    /// After `applyFit` runs, `ViewerController.currentMagnification` must
    /// match the live scroll-view magnification — otherwise the toolbar's
    /// `isAtFit` check would drift and the fit-mode button highlight would
    /// be out of sync.
    @Test func applyFitSyncsViewerControllerCurrentMagnification() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        let viewerController = ViewerController()
        viewerController.attach(scrollView: scrollView)
        coordinator.viewerController = viewerController

        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true
        )

        #expect(abs(viewerController.currentMagnification - scrollView.magnification) < 0.001)
        #expect(viewerController.isAtFit)
    }

    /// And after a non-force apply that preserves the user's manual zoom,
    /// `currentMagnification` still tracks the live scroll-view value (the
    /// preserved mag, not the new fit). `isAtFit` is false because the user
    /// is no longer at the new baseline.
    @Test func applyFitNonForceLeavesUserZoomedAndOffFit() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        let viewerController = ViewerController()
        viewerController.attach(scrollView: scrollView)
        coordinator.viewerController = viewerController

        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true
        )
        // User zooms in.
        scrollView.magnification = 2.0
        viewerController.currentMagnification = 2.0

        // Some non-force trigger (page flip / new book / layout swap).
        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: false
        )

        #expect(abs(scrollView.magnification - 2.0) < 0.001)
        #expect(abs(viewerController.currentMagnification - 2.0) < 0.001)
        #expect(viewerController.isAtFit == false)
    }

    /// Pressing the fit button still snaps to fit even if the user had
    /// zoomed — that's the button's job, and the only path that overrides
    /// the user's manual magnification.
    @Test func fitButtonStillSnapsWhenUserHasZoomed() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true
        )
        scrollView.magnification = 2.0

        // User picks fit-width — fitModeChanged → force in production.
        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitWidth,
            force: true
        )

        let expected = FitCalculator.magnification(
            docSize: doc.frame.size,
            viewport: scrollView.contentSize,
            fitMode: .fitWidth
        )
        #expect(abs(scrollView.magnification - expected) < 0.001)
    }

    /// Counterpart: if the user has *not* manually zoomed, navigating to the
    /// next page should snap to the new page's fit (so a taller page doesn't
    /// stay framed at the previous page's magnification).
    @Test func fitFollowsNextPageWhenUserHasNotZoomed() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let firstPage = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = firstPage
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true
        )
        let firstFit = scrollView.magnification

        // Different-sized next page, user never zoomed.
        let secondPage = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 2400))
        scrollView.documentView = secondPage
        scrollView.layoutSubtreeIfNeeded()

        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: false
        )

        let expectedFit = FitCalculator.magnification(
            docSize: secondPage.frame.size,
            viewport: scrollView.contentSize,
            fitMode: .fitScreen
        )
        #expect(abs(scrollView.magnification - expectedFit) < 0.001)
        // Sanity: the taller second page has a smaller fit-screen mag.
        #expect(scrollView.magnification < firstFit)
    }

    /// When autoFitOnResize is OFF (locked), applyFit must preserve the
    /// current magnification even when the user hasn't manually zoomed —
    /// otherwise layout changes / view option toggles would still trigger
    /// auto-resizing in vertical mode while the user expected lock to hold.
    @Test func applyFitWithLockPreservesMagnificationOnDocSizeChange() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        // Initial fit-screen → mag ≈ 0.4
        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true
        )
        let firstMag = scrollView.magnification

        // Lock the view
        coordinator.autoFitOnResize = false

        // Simulate doc-size change (e.g., layout switch to a strip with a
        // larger first image). New fit would be ~0.2 if applied.
        doc.frame = NSRect(x: 0, y: 0, width: 2000, height: 3000)
        scrollView.layoutSubtreeIfNeeded()

        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: false
        )

        // Lock holds — magnification didn't follow the new fit.
        #expect(abs(scrollView.magnification - firstMag) < 0.001)
    }

    @Test func applyFitWithoutLockResetsOnDocSizeChangeWhenNotZoomed() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        coordinator.autoFitOnResize = true // default
        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true
        )
        let firstMag = scrollView.magnification

        doc.frame = NSRect(x: 0, y: 0, width: 2000, height: 3000)
        scrollView.layoutSubtreeIfNeeded()

        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: false
        )

        // No lock + not zoomed → magnification follows the new fit.
        #expect(scrollView.magnification < firstMag)
    }

    /// Force-reset (identity / fit-mode change) bypasses the lock — opening
    /// a new book or pressing ⌘1/⌘2/⌘3 is an explicit user choice.
    @Test func applyFitWithLockStillResetsOnForce() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        coordinator.autoFitOnResize = false // locked
        scrollView.magnification = 2.0

        AppKitImageScroller.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: .fitScreen,
            force: true // user chose new fit mode or new book
        )

        // Force overrides lock — mag snapped to fit-screen (~0.4)
        #expect(abs(scrollView.magnification - 0.4) < 0.01)
    }

    /// Coordinator must remove its NotificationCenter observer on deinit, or
    /// posting frame-change notifications after the view tree is torn down
    /// will dispatch into a dead reference. We attach via the public API
    /// (same path production uses) so the test guards the real cleanup.
    @Test func coordinatorRemovesFrameObserverOnDeinit() {
        weak var weakCoordinator: AppKitScrollerCoordinator?
        do {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            scrollView.postsFrameChangedNotifications = true
            let coordinator = AppKitScrollerCoordinator()
            coordinator.scrollView = scrollView
            coordinator.attachFrameObserver(to: scrollView)
            weakCoordinator = coordinator
            #expect(weakCoordinator != nil)
        }
        // Without explicit removeObserver in deinit the closure-token observer
        // would keep the Coordinator (or its captured state) alive in some
        // configurations; we just assert the Coordinator itself was released.
        #expect(weakCoordinator == nil)
    }

    private static func makeScrollView(size: CGSize) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 10.0
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.postsFrameChangedNotifications = true
        return scrollView
    }
}
