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
    /// Series the current book belongs to. When `identity` (the book) changes
    /// but `seriesIdentity` stays the same, the user moved between sibling
    /// volumes of one series — that's when the manual zoom carries over (see
    /// `captureZoomCarryOverIfBookChanged`). A different series resets to fit.
    var seriesIdentity: String = ""
    var onPageIndexChanged: (Int) -> Void = { _ in }
    var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }
    var autoFitOnResize: Bool = true
    /// User preference: plain scroll turns pages in paged layouts. Combined
    /// with the layout below — continuous mode never intercepts scrolling.
    var wheelPageTurn: Bool = true
    var onWheelPageTurn: (PageTurnDirection) -> Void = { _ in }
    var viewerController: ViewerController? = nil

    /// Looser than `ViewerController.fitTolerance` (10×) on purpose: a tiny
    /// stray manual zoom should still count as "at base" so the first
    /// double-click zooms in, rather than snapping back to an
    /// imperceptibly-different fit magnification.
    static let doubleClickBaseTolerance: CGFloat = 0.01

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

        // Read the outgoing series before recordPropChange commits the new one,
        // so the carry-over can stash where we left it.
        let previousSeriesIdentity = context.coordinator.lastSeriesIdentity
        let diff = recordPropChange(
            into: context.coordinator,
            contentStructureChanged: contentStructureChanged
        )
        captureZoomCarryOverIfBookChanged(scrollView: scrollView, coordinator: context.coordinator, diff: diff, previousSeriesIdentity: previousSeriesIdentity)
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
            let isAtBase = abs(scrollView.magnification - coordinator.baseMagnification) < AppKitImageScroller.doubleClickBaseTolerance
            // Clamp the zoom-in target so a small image with a large fit base
            // doesn't request a magnification past the scroll view's ceiling
            // (setMagnification clamps anyway, but clamping here keeps the
            // toggle predictable and the synced value below honest).
            let target = isAtBase
                ? min(coordinator.baseMagnification * 2, scrollView.maxMagnification)
                : coordinator.baseMagnification
            scrollView.setMagnification(target, centeredAt: localPoint)
            // Sync explicitly. The bounds observer would catch this too, but
            // every other zoom path (`ViewerController.zoomIn/zoomOut/resetZoom`,
            // `applyFit`) updates `currentMagnification` inline; relying on the
            // observer here would leave double-click as the only path that
            // depends on observer timing for the toolbar's `isAtFit` highlight.
            coordinator.viewerController?.currentMagnification = scrollView.magnification
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
        // Continuous mode always wins: there, scrolling is the reading
        // gesture itself and must reach the scroll view untouched.
        scrollView.wheelPageTurnEnabled = wheelPageTurn && !layout.isContinuous
        scrollView.onPageTurn = onWheelPageTurn
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

        /// The *only* event that overrides the user's manual zoom is them
        /// pressing the fit button (or hitting a fit shortcut), which flips
        /// `fitMode` and surfaces here as `fitModeChanged`. New-book / layout
        /// / page changes intentionally do **not** force: the user's chosen
        /// magnification is their preference, and the non-force path in
        /// `applyFit` still snaps to the new content's fit when they
        /// *haven't* manually zoomed (so a fresh user never sees a stuck
        /// magnification).
        var forceFitReset: Bool {
            AppKitImageScroller.shouldForceFitReset(
                fitModeChanged: fitModeChanged
            )
        }
    }

    static func shouldForceFitReset(fitModeChanged: Bool) -> Bool {
        // Only the fit-mode button forces a re-fit. That button's literal
        // job is "apply this fit now," so it has to win. Everything else
        // (new book, layout swap, page flip, viewport resize) defers to the
        // non-force path: if the user manually zoomed, their magnification
        // is preserved; if they didn't, magnification follows the new fit.
        return fitModeChanged
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
        coordinator.lastSeriesIdentity = seriesIdentity
        coordinator.lastFitMode = fitMode
        coordinator.lastLayout = layout
        return diff
    }

    /// On a book switch, decide how the user's manual zoom carries into the
    /// next book and stash it as `pendingZoomFactor` for `applyFit` to consume
    /// once the new strip has a valid size. Read at this moment so
    /// `scrollView.magnification` / `baseMagnification` still reflect the
    /// *previous* book (the new fit hasn't been applied yet):
    /// - different series, or the user was at fit → factor 1.0 (snap to the new
    ///   book's fit; a clean slate when jumping series)
    /// - same series with an escaped zoom → carry the fit-relative ratio so the
    ///   page keeps the same on-screen scale across sibling volumes
    /// Skipped entirely when auto-fit is locked off — the user has taken manual
    /// control, so the existing preserve-absolute path is left untouched.
    private func captureZoomCarryOverIfBookChanged(scrollView: PanelyScrollView, coordinator: AppKitScrollerCoordinator, diff: PropDiff, previousSeriesIdentity: String) {
        guard diff.identityChanged, coordinator.autoFitOnResize else { return }
        coordinator.pendingZoomFactor = Self.resolveSeriesZoom(
            previousSeriesID: previousSeriesIdentity,
            newSeriesID: seriesIdentity,
            baseMagnification: coordinator.baseMagnification,
            magnification: scrollView.magnification,
            memory: &coordinator.sessionZoomBySeriesID
        )
    }

    /// Pure carry-over policy — extracted so it's unit-testable without a live
    /// scroll view (mirrors `shouldResetMagnification`). Called at a book
    /// switch with the *previous* book's fit baseline and live magnification:
    ///
    /// 1. Record where we left the previous series — its escaped fit-relative
    ///    zoom (`magnification / baseFit`), or clear it if the user was at fit,
    ///    so returning later restores that exact state.
    /// 2. Pick the factor for the next book:
    ///    - same series → keep the current zoom (carry across sibling volumes)
    ///    - different series → restore that series' remembered zoom from session
    ///      memory, or 1.0 (snap to fit) if it has none.
    ///
    /// A factor of 1.0 means "the new book's own fit". `memory` is mutated in
    /// place (the coordinator's session map).
    static func resolveSeriesZoom(
        previousSeriesID: String,
        newSeriesID: String,
        baseMagnification: CGFloat,
        magnification: CGFloat,
        memory: inout [String: CGFloat]
    ) -> CGFloat {
        let escapedFactor: CGFloat? = (baseMagnification > 0
            && abs(magnification - baseMagnification) > ViewerController.fitTolerance)
            ? magnification / baseMagnification
            : nil

        if !previousSeriesID.isEmpty {
            // nil (at fit) clears the slot so a later return lands at fit.
            memory[previousSeriesID] = escapedFactor
        }

        if previousSeriesID == newSeriesID {
            return escapedFactor ?? 1.0
        }
        return memory[newSeriesID] ?? 1.0
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
        let docSize = fitReferenceSize(for: content)
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

        // One-shot zoom carry-over from a book switch (set by
        // `captureZoomCarryOverIfBookChanged`). Apply `factor × fit` and adopt
        // the new book's fit as the baseline, so reset/double-click land
        // correctly. Consumed here — the first fit with a valid doc size after
        // the switch — so the staged vertical rebuild's empty-strip ticks
        // (which bail at the size guard above) don't swallow it.
        if let factor = coordinator.pendingZoomFactor {
            coordinator.pendingZoomFactor = nil
            let target = min(max(fit * factor, scrollView.minMagnification), scrollView.maxMagnification)
            scrollView.magnification = target
            coordinator.hasAppliedInitialFit = true
            if coordinator.baseMagnification != fit {
                coordinator.baseMagnification = fit
            }
            let magnification = scrollView.magnification
            if let viewerController = coordinator.viewerController,
               viewerController.currentMagnification != magnification {
                viewerController.currentMagnification = magnification
            }
            return
        }

        let userHasZoomed = abs(scrollView.magnification - coordinator.baseMagnification) > ViewerController.fitTolerance
        let shouldReset = shouldResetMagnification(
            force: force,
            hasAppliedInitialFit: coordinator.hasAppliedInitialFit,
            autoFitOnResize: coordinator.autoFitOnResize,
            userHasZoomed: userHasZoomed
        )

        if shouldReset {
            scrollView.magnification = fit
        }
        coordinator.hasAppliedInitialFit = true
        // `baseMagnification`/`currentMagnification` forward to the @Observable
        // ViewerController (the sole owner — the toolbar observes them via
        // `isAtFit`, `resetZoom` reads them). The Observation framework
        // invalidates on *every* write, with no old==new check. Because
        // `applyFit` runs from `updateNSView`, an unconditional write here
        // re-invalidates the toolbar, which re-runs `updateNSView`, which calls
        // `applyFit` again → an infinite SwiftUI update loop pinning the main
        // thread. (Latent until a book settles at a stable fit so `applyFit`
        // keeps re-writing identical values; catastrophic on a large library
        // where each toolbar render does per-sibling filesystem work.) Writing
        // only on an actual change breaks the cycle — a real user zoom still
        // changes `scrollView.magnification`, so the highlight stays in sync.
        if coordinator.baseMagnification != fit {
            coordinator.baseMagnification = fit
        }
        let magnification = scrollView.magnification
        if let viewerController = coordinator.viewerController,
           viewerController.currentMagnification != magnification {
            viewerController.currentMagnification = magnification
        }
    }

    /// Pure fit-reset policy — extracted so it's unit-testable without a live
    /// `NSScrollView` (mirrors `shouldForceFitReset`). The first valid fit and
    /// an explicit `force` always reset; a locked view (`autoFitOnResize ==
    /// false`) never does; otherwise reset only when the user hasn't manually
    /// zoomed away from the fit baseline.
    static func shouldResetMagnification(
        force: Bool,
        hasAppliedInitialFit: Bool,
        autoFitOnResize: Bool,
        userHasZoomed: Bool
    ) -> Bool {
        if force || !hasAppliedInitialFit { return true }
        if !autoFitOnResize { return false }
        return !userHasZoomed
    }

    /// The document size fit should be computed against. For vertical
    /// (continuous) strips, fitting the entire stack height collapses
    /// everything to a sliver, so fit against the first page instead —
    /// fit-screen means "first page visible", fit-width means "first page
    /// fills the viewport width".
    private static func fitReferenceSize(for content: NSView) -> CGSize {
        if let stack = content as? ImageStackView,
           stack.axis == .vertical,
           let firstFrame = stack.frame(forPageAt: 0) {
            return firstFrame.size
        }
        return content.frame.size
    }
}
