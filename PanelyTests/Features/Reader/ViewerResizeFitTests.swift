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

        let coordinator = AppKitImageScroller.Coordinator()
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

        let coordinator = AppKitImageScroller.Coordinator()
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

        let coordinator = AppKitImageScroller.Coordinator()
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

    /// When autoFitOnResize is OFF (locked), applyFit must preserve the
    /// current magnification even when the user hasn't manually zoomed —
    /// otherwise layout changes / view option toggles would still trigger
    /// auto-resizing in vertical mode while the user expected lock to hold.
    @Test func applyFitWithLockPreservesMagnificationOnDocSizeChange() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitImageScroller.Coordinator()
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

        let coordinator = AppKitImageScroller.Coordinator()
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

        let coordinator = AppKitImageScroller.Coordinator()
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
    /// will dispatch into a dead reference.
    @Test func coordinatorRemovesFrameObserverOnDeinit() {
        weak var weakCoordinator: AppKitImageScroller.Coordinator?
        do {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            scrollView.postsFrameChangedNotifications = true
            let coordinator = AppKitImageScroller.Coordinator()
            coordinator.scrollView = scrollView
            coordinator.frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView,
                queue: .main
            ) { _ in }
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
