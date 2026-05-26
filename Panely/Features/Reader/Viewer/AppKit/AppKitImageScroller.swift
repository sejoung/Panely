import AppKit
import SwiftUI

/// SwiftUI ↔ AppKit bridge for the image viewer. Hosts a `PanelyScrollView`
/// with an `ImageStackView` document and forwards SwiftUI prop changes
/// (images / layout / fit / page) into the AppKit world. The observer
/// wiring + change diffing lives on `AppKitScrollerCoordinator` so this
/// representable stays focused on the handshake itself.
struct AppKitImageScroller: NSViewRepresentable {
    let images: [NSImage]
    let direction: ReadingDirection
    let fitMode: FitMode
    let layout: PageLayout
    let pageIndex: Int
    let identity: String
    var onPageIndexChanged: (Int) -> Void = { _ in }
    var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }
    var autoFitOnResize: Bool = true
    var viewerController: ViewerController? = nil

    func makeCoordinator() -> AppKitScrollerCoordinator {
        AppKitScrollerCoordinator()
    }

    func makeNSView(context: Context) -> PanelyScrollView {
        let scrollView = makeConfiguredScrollView()
        let content = makeContentView(in: scrollView, coordinator: context.coordinator)
        scrollView.documentView = content

        let coordinator = context.coordinator
        coordinator.scrollView = scrollView
        coordinator.viewerController = viewerController
        coordinator.onPageIndexChanged = onPageIndexChanged
        coordinator.onVisibleRangeChanged = onVisibleRangeChanged
        viewerController?.attach(scrollView: scrollView)

        coordinator.attachFrameObserver(to: scrollView)
        coordinator.attachBoundsObserver(to: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: PanelyScrollView, context: Context) {
        guard let content = scrollView.documentView as? ImageStackView else { return }

        refreshCoordinatorBindings(context.coordinator, scrollView: scrollView)
        let contentStructureChanged = updateContentImages(content)

        let diff = recordPropChange(
            into: context.coordinator,
            contentStructureChanged: contentStructureChanged
        )
        applyFitIfNeeded(scrollView: scrollView, coordinator: context.coordinator, diff: diff)
        syncScrollPositionIfNeeded(scrollView: scrollView, content: content, coordinator: context.coordinator)
        kickInitialVisibleRangeIfVertical(scrollView: scrollView, content: content, coordinator: context.coordinator)
    }

    // MARK: - makeNSView helpers

    private func makeConfiguredScrollView() -> PanelyScrollView {
        let scrollView = PanelyScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 10.0
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        return scrollView
    }

    private func makeContentView(in scrollView: PanelyScrollView, coordinator: AppKitScrollerCoordinator) -> ImageStackView {
        let content = ImageStackView()
        content.onDoubleClick = { [weak scrollView] localPoint in
            guard let scrollView else { return }
            let isAtBase = abs(scrollView.magnification - coordinator.baseMagnification) < 0.01
            let target = isAtBase ? coordinator.baseMagnification * 2 : coordinator.baseMagnification
            scrollView.setMagnification(target, centeredAt: localPoint)
        }
        return content
    }

    // MARK: - updateNSView helpers

    /// Stash fresh closures + flags on the coordinator. SwiftUI rebuilds
    /// props each tick, but the observer only retains what we hand it at
    /// registration time — re-stashing here keeps the closures current.
    private func refreshCoordinatorBindings(_ coordinator: AppKitScrollerCoordinator, scrollView: PanelyScrollView) {
        coordinator.onPageIndexChanged = onPageIndexChanged
        coordinator.onVisibleRangeChanged = onVisibleRangeChanged
        coordinator.autoFitOnResize = autoFitOnResize
        coordinator.viewerController = viewerController
        viewerController?.attach(scrollView: scrollView)
    }

    private func updateContentImages(_ content: ImageStackView) -> Bool {
        let axis: ImageStackView.Axis = layout.isContinuous ? .vertical : .horizontal
        // RTL only applies to paged horizontal modes — webtoon strips are top-to-bottom.
        let ordered = (direction.isRTL && !layout.isContinuous) ? images.reversed() : images
        return content.setImages(ordered, axis: axis)
    }

    /// Compares incoming props against the coordinator's last-seen snapshot,
    /// then commits the new snapshot. Split out so `updateNSView` can read
    /// the diff before deciding to force a fit reset or just track the new
    /// page index.
    private struct PropDiff {
        let identityChanged: Bool
        let fitModeChanged: Bool
        let layoutChanged: Bool
        let contentStructureChanged: Bool
        let pageChanged: Bool

        /// Structural changes that demand we re-layout the scroll subtree
        /// before applying fit.
        var needsLayoutReset: Bool {
            identityChanged || fitModeChanged || layoutChanged || contentStructureChanged
        }

        /// Fundamental changes that override the user's manual zoom: a new
        /// book, an explicit fit-mode pick, or a layout swap. `contentStructureChanged`
        /// is deliberately excluded — in paged mode every page-flip swaps the
        /// NSImage array (so structure "changes"), and we want the user's
        /// zoom to survive flipping to the next page. The non-force path in
        /// `applyFit` still snaps to the new page's fit when the user *hasn't*
        /// manually zoomed.
        var forceFitReset: Bool {
            AppKitImageScroller.shouldForceFitReset(
                identityChanged: identityChanged,
                fitModeChanged: fitModeChanged,
                layoutChanged: layoutChanged,
                contentStructureChanged: contentStructureChanged
            )
        }
    }

    static func shouldForceFitReset(
        identityChanged: Bool,
        fitModeChanged: Bool,
        layoutChanged: Bool,
        contentStructureChanged: Bool
    ) -> Bool {
        // `contentStructureChanged` intentionally not OR'd in: routine page
        // navigation in paged mode trips this flag every flip, and we want
        // the user's manual zoom to carry across pages. New-book / layout-swap
        // cases are already caught by `identityChanged` / `layoutChanged`.
        _ = contentStructureChanged
        return identityChanged || fitModeChanged || layoutChanged
    }

    private func recordPropChange(
        into coordinator: AppKitScrollerCoordinator,
        contentStructureChanged: Bool
    ) -> PropDiff {
        let diff = PropDiff(
            identityChanged: coordinator.lastIdentity != identity,
            fitModeChanged: coordinator.lastFitMode != fitMode,
            layoutChanged: coordinator.lastLayout != layout,
            contentStructureChanged: contentStructureChanged,
            // Don't pre-set lastPageIndex here. We only mark a page as
            // "successfully shown" after the scroll actually lands (see
            // syncScrollPositionIfNeeded), otherwise initial vertical
            // renders that happen before the strip has the target index
            // would be silently dropped on subsequent ticks.
            pageChanged: coordinator.lastPageIndex != pageIndex
        )
        coordinator.lastIdentity = identity
        coordinator.lastFitMode = fitMode
        coordinator.lastLayout = layout
        return diff
    }

    private func applyFitIfNeeded(scrollView: PanelyScrollView, coordinator: AppKitScrollerCoordinator, diff: PropDiff) {
        // Apply fit synchronously so the user never sees a frame at the
        // previous magnification (which manifested as the image briefly
        // sliding/centering before snapping to fit-width on layout toggles).
        // Only force layout when something structural just changed — per-page
        // navigation in paged mode and lazy-load image swaps in vertical
        // mode keep frames stable, so layoutSubtreeIfNeeded would just walk
        // the (potentially 1000-deep) view tree for nothing.
        if diff.needsLayoutReset {
            scrollView.layoutSubtreeIfNeeded()
        }
        Self.applyFit(
            scrollView: scrollView,
            coordinator: coordinator,
            fitMode: fitMode,
            force: diff.forceFitReset
        )
    }

    private func syncScrollPositionIfNeeded(scrollView: PanelyScrollView, content: ImageStackView, coordinator: AppKitScrollerCoordinator) {
        if layout.isContinuous && coordinator.lastPageIndex != pageIndex,
           let frame = content.frame(forPageAt: pageIndex) {
            // Suppress only the page-index callback during programmatic
            // scroll (avoids feedback). Visible-range callback is allowed to
            // fire so lazy loading kicks in for the newly-visible window —
            // critical when restoring a saved position into a strip that's
            // mostly placeholders.
            coordinator.isProgrammaticallyScrolling = true
            let currentX = scrollView.contentView.bounds.origin.x
            scrollView.contentView.scroll(to: NSPoint(x: currentX, y: frame.minY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            coordinator.isProgrammaticallyScrolling = false
            coordinator.lastPageIndex = pageIndex
        } else if !layout.isContinuous {
            // Paged mode never scrolls itself; just record the index.
            coordinator.lastPageIndex = pageIndex
        }
        // Vertical with no frame yet (stack still being populated): leave
        // lastPageIndex stale so the next updateNSView retries.
    }

    /// The bounds observer doesn't always fire on the first vertical render
    /// (stack just installed, no actual scroll movement yet), so compute and
    /// dispatch the visible range here too. Cheap when nothing changed
    /// (range == lastVisibleRange short-circuits the callback).
    private func kickInitialVisibleRangeIfVertical(scrollView: PanelyScrollView, content: ImageStackView, coordinator: AppKitScrollerCoordinator) {
        guard layout.isContinuous else { return }
        let visibleRect = scrollView.documentVisibleRect
        let range = content.pageIndexRange(visibleIn: visibleRect)
        if range != coordinator.lastVisibleRange {
            coordinator.lastVisibleRange = range
            onVisibleRangeChanged(range)
        }
        // Materialize the initial visible-window views right away — the
        // bounds observer won't fire if the scroll position didn't actually
        // move (e.g., loading the first vertical strip landing at scroll
        // y=0 with no prior bounds change).
        content.refreshVisibleViews(visibleRect: visibleRect)
    }

    // MARK: - Fit application

    static func applyFit(
        scrollView: NSScrollView,
        coordinator: AppKitScrollerCoordinator,
        fitMode: FitMode,
        force: Bool
    ) {
        guard let content = scrollView.documentView else { return }
        // For vertical (continuous) strips, fitting against the entire stack
        // height collapses everything to a sliver. Use the first image as
        // the reference instead so fit-screen means "first page visible"
        // and fit-width means "first page fills viewport width".
        let docSize: CGSize
        if let stack = content as? ImageStackView,
           stack.axis == .vertical,
           let firstFrame = stack.frame(forPageAt: 0) {
            docSize = firstFrame.size
        } else {
            docSize = content.frame.size
        }
        // contentSize is the physical viewport (magnification-invariant);
        // using contentView.bounds.size here would feed back into itself
        // because it scales inversely with magnification, causing toggled
        // fits to drift.
        let viewport = scrollView.contentSize
        guard docSize.width > 0, docSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return }

        let fit = FitCalculator.magnification(
            docSize: docSize,
            viewport: viewport,
            fitMode: fitMode
        )

        let userHasZoomed = abs(scrollView.magnification - coordinator.baseMagnification) > 0.001

        // Force (identity / fitMode change) always wins — those are explicit
        // user actions or fundamental content changes. Otherwise the lock
        // (autoFitOnResize=false) preserves the current magnification even
        // when the user hasn't manually zoomed yet — that's the whole point
        // of locking the view size.
        let shouldReset: Bool
        if force {
            shouldReset = true
        } else if !coordinator.autoFitOnResize {
            shouldReset = false
        } else {
            shouldReset = !userHasZoomed
        }

        if shouldReset {
            scrollView.magnification = fit
        }
        coordinator.baseMagnification = fit
        coordinator.viewerController?.baseMagnification = fit
    }
}
