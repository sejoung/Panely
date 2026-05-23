import AppKit
import SwiftUI

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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PanelyScrollView {
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

        let content = ImageStackView()
        content.onDoubleClick = { [weak scrollView] localPoint in
            guard let scrollView else { return }
            let coord = context.coordinator
            let isAtBase = abs(scrollView.magnification - coord.baseMagnification) < 0.01
            let target = isAtBase ? coord.baseMagnification * 2 : coord.baseMagnification
            scrollView.setMagnification(target, centeredAt: localPoint)
        }
        scrollView.documentView = content

        context.coordinator.scrollView = scrollView
        context.coordinator.viewerController = viewerController
        viewerController?.attach(scrollView: scrollView)

        // Defensive: makeNSView normally runs exactly once per Coordinator
        // lifetime, but SwiftUI is free to recreate the representable. If a
        // prior coordinator hand-off ever leaks an observer here it would
        // double-fire the auto-fit on every resize. Cheap to guard.
        if let existing = context.coordinator.frameObserver {
            NotificationCenter.default.removeObserver(existing)
            context.coordinator.frameObserver = nil
        }
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator,
                      let sv = coordinator.scrollView,
                      coordinator.autoFitOnResize else { return }
                Self.applyFit(
                    scrollView: sv,
                    coordinator: coordinator,
                    fitMode: coordinator.lastFitMode,
                    force: false
                )
            }
        }

        scrollView.contentView.postsBoundsChangedNotifications = true
        let coordinator = context.coordinator
        coordinator.onPageIndexChanged = onPageIndexChanged
        coordinator.onVisibleRangeChanged = onVisibleRangeChanged
        // queue: nil → synchronous on the posting thread (always main here),
        // so currentPageIndex is always fresh when the user clicks a button.
        if let existing = coordinator.boundsObserver {
            NotificationCenter.default.removeObserver(existing)
            coordinator.boundsObserver = nil
        }
        coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: nil
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator,
                      let sv = coordinator.scrollView,
                      coordinator.lastLayout.isContinuous,
                      let stack = sv.documentView as? ImageStackView else { return }
                let visibleRect = sv.documentVisibleRect

                // Page-index callback is suppressed during programmatic
                // scroll so the model doesn't feedback-loop.
                if !coordinator.isProgrammaticallyScrolling {
                    let centerY = visibleRect.midY
                    let visibleIndex = stack.pageIndex(forViewportY: centerY)
                    if visibleIndex != coordinator.lastPageIndex {
                        coordinator.lastPageIndex = visibleIndex
                        coordinator.onPageIndexChanged(visibleIndex)
                    }
                }

                // Visible-range callback always fires — required for lazy
                // loading to populate slots after auto-scroll to a restored
                // position or after large jumps.
                let visibleRange = stack.pageIndexRange(visibleIn: visibleRect)
                if visibleRange != coordinator.lastVisibleRange {
                    coordinator.lastVisibleRange = visibleRange
                    coordinator.onVisibleRangeChanged(visibleRange)
                }

                // Materialize NSImageViews for newly-visible pages, recycle
                // ones that scrolled out. Keeps the view tree small even on
                // 1000-page strips.
                stack.refreshVisibleViews(visibleRect: visibleRect)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: PanelyScrollView, context: Context) {
        guard let content = scrollView.documentView as? ImageStackView else { return }

        // Keep the closure fresh — SwiftUI rebuilds props each tick, but the
        // observer only retains what we hand it at registration time.
        context.coordinator.onPageIndexChanged = onPageIndexChanged
        context.coordinator.onVisibleRangeChanged = onVisibleRangeChanged
        context.coordinator.autoFitOnResize = autoFitOnResize
        context.coordinator.viewerController = viewerController
        viewerController?.attach(scrollView: scrollView)

        let axis: ImageStackView.Axis = layout.isContinuous ? .vertical : .horizontal
        // RTL only applies to paged horizontal modes — webtoon strips are top-to-bottom.
        let ordered = (direction.isRTL && !layout.isContinuous) ? images.reversed() : images
        content.setImages(ordered, axis: axis)

        // resetNeeded drives setImages' identity check + applyFit's force.
        // We split the "should we force-reset magnification" decision so that
        // a layout-only change (e.g., single → vertical) preserves a user's
        // manual zoom; only identity (new book) or fitMode (user pressed
        // ⌘1/⌘2/⌘3) explicitly resets.
        let identityChanged = context.coordinator.lastIdentity != identity
        let fitModeChanged = context.coordinator.lastFitMode != fitMode
        let layoutChanged = context.coordinator.lastLayout != layout
        let resetNeeded = identityChanged || fitModeChanged || layoutChanged
        let forceFitReset = identityChanged || fitModeChanged
        context.coordinator.lastIdentity = identity
        context.coordinator.lastFitMode = fitMode
        context.coordinator.lastLayout = layout

        // Note: don't pre-set lastPageIndex here. We only mark a page as
        // "successfully shown" after the scroll actually lands (see below),
        // otherwise initial vertical renders that happen before the strip
        // has the target index in its stack would be silently dropped on
        // subsequent ticks (pageChanged would be false even though we never
        // scrolled).
        let pageChanged = context.coordinator.lastPageIndex != pageIndex

        // Apply fit synchronously so the user never sees a frame at the
        // previous magnification (which manifested as the image briefly
        // sliding/centering before snapping to fit-width on layout toggles).
        // Only force layout when something structural just changed —
        // per-page navigation in paged mode and lazy-load image swaps in
        // vertical mode keep frames stable, so layoutSubtreeIfNeeded would
        // just walk the (potentially 1000-deep) view tree for nothing.
        if resetNeeded {
            scrollView.layoutSubtreeIfNeeded()
        }
        Self.applyFit(
            scrollView: scrollView,
            coordinator: context.coordinator,
            fitMode: fitMode,
            force: forceFitReset
        )

        if layout.isContinuous && pageChanged,
           let frame = content.frame(forPageAt: pageIndex) {
            // Suppress only the page-index callback during programmatic
            // scroll (avoids feedback). Visible-range callback is allowed to
            // fire so lazy loading kicks in for the newly-visible window —
            // critical when restoring a saved position into a strip that's
            // mostly placeholders.
            context.coordinator.isProgrammaticallyScrolling = true
            let currentX = scrollView.contentView.bounds.origin.x
            scrollView.contentView.scroll(to: NSPoint(x: currentX, y: frame.minY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            context.coordinator.isProgrammaticallyScrolling = false
            context.coordinator.lastPageIndex = pageIndex
        } else if !layout.isContinuous {
            // Paged mode never scrolls itself; just record the index.
            context.coordinator.lastPageIndex = pageIndex
        }
        // Vertical with no frame yet (stack still being populated): leave
        // lastPageIndex stale so the next updateNSView retries.

        // Ensure lazy loading kicks in for whatever's currently visible —
        // the bounds observer doesn't always fire on the first vertical
        // render (stack just installed, no actual scroll movement yet), so
        // we recompute and dispatch the range here too. Cheap when nothing
        // changed (range == lastVisibleRange short-circuits the callback).
        if layout.isContinuous {
            let visibleRect = scrollView.documentVisibleRect
            let range = content.pageIndexRange(visibleIn: visibleRect)
            if range != context.coordinator.lastVisibleRange {
                context.coordinator.lastVisibleRange = range
                onVisibleRangeChanged(range)
            }
            // Materialize the initial visible-window views right away —
            // bounds observer won't fire if the scroll position didn't
            // actually move (e.g., loading the first vertical strip
            // landing at scroll y=0 with no prior bounds change).
            content.refreshVisibleViews(visibleRect: visibleRect)
        }
    }

    static func applyFit(
        scrollView: NSScrollView,
        coordinator: Coordinator,
        fitMode: FitMode,
        force: Bool
    ) {
        guard let content = scrollView.documentView else { return }
        // For vertical (continuous) strips, fitting against the entire stack
        // height collapses everything to a sliver. Use the first image as the
        // reference instead so fit-screen means "first page visible" and
        // fit-width means "first page fills viewport width".
        let docSize: CGSize
        if let stack = content as? ImageStackView,
           stack.axis == .vertical,
           let firstFrame = stack.frame(forPageAt: 0) {
            docSize = firstFrame.size
        } else {
            docSize = content.frame.size
        }
        // contentSize is the physical viewport (magnification-invariant); using
        // contentView.bounds.size here would feed back into itself because it
        // scales inversely with magnification, causing toggled fits to drift.
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

    @MainActor
    final class Coordinator {
        var lastIdentity: String = ""
        var lastFitMode: FitMode = .fitScreen
        var lastLayout: PageLayout = .single
        var lastPageIndex: Int = -1
        var lastVisibleRange: Range<Int> = 0..<0
        var baseMagnification: CGFloat = 1.0
        var isProgrammaticallyScrolling: Bool = false
        var autoFitOnResize: Bool = true
        weak var scrollView: NSScrollView?
        weak var viewerController: ViewerController?
        var frameObserver: NSObjectProtocol?
        var boundsObserver: NSObjectProtocol?
        var onPageIndexChanged: (Int) -> Void = { _ in }
        var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }

        deinit {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }
    }
}
