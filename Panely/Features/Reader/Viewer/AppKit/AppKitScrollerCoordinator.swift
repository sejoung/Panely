import AppKit

/// Holds the AppKit-side state for `AppKitImageScroller` — tracks the last
/// SwiftUI props it saw (for change detection), owns the two
/// NotificationCenter observer tokens, and applies the fit-mode magnification
/// when the viewport resizes.
///
/// Lives off the representable so `AppKitImageScroller.makeNSView` /
/// `updateNSView` stay focused on the SwiftUI ↔ AppKit handshake instead of
/// being half observer-wiring, half state diffing.
@MainActor
final class AppKitScrollerCoordinator {
    var lastIdentity: String = ""
    var lastFitMode: FitMode = .fitScreen
    var lastLayout: PageLayout = .single
    var lastPageIndex: Int = -1
    var lastVisibleRange: Range<Int> = 0..<0
    var baseMagnification: CGFloat = 1.0
    var isProgrammaticallyScrolling: Bool = false
    var autoFitOnResize: Bool = true

    /// False until the first valid `applyFit` runs. The very first fit must
    /// snap to the computed magnification unconditionally — if it happened to
    /// run while `scrollView.magnification` was at a transient default that
    /// differs from `baseMagnification`, the `userHasZoomed` heuristic would
    /// spuriously read `true` and suppress the fit, leaving the page rendered
    /// at the wrong (or zero) magnification.
    var hasAppliedInitialFit: Bool = false

    weak var scrollView: NSScrollView?
    weak var viewerController: ViewerController?

    var onPageIndexChanged: (Int) -> Void = { _ in }
    var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }

    private var frameObserver: NSObjectProtocol?
    private var boundsObserver: NSObjectProtocol?

    deinit {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
        }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    // MARK: - Observer attachment

    /// Reapply the current fit mode every time the scroll view's frame
    /// changes (window resize, sidebar pin/unpin). Defensive teardown of any
    /// prior observer — `makeNSView` normally runs once per Coordinator, but
    /// SwiftUI is free to recreate the representable; without this, a leaked
    /// observer would double-fire on every resize.
    func attachFrameObserver(to scrollView: NSScrollView) {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
            self.frameObserver = nil
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let sv = self.scrollView,
                      self.autoFitOnResize else { return }
                AppKitImageScroller.applyFit(
                    scrollView: sv,
                    coordinator: self,
                    fitMode: self.lastFitMode,
                    force: false
                )
            }
        }
    }

    /// Watch the clip view for scroll changes so we can update the model's
    /// page index, the visible-range subscription, and recycle pages out of
    /// the visible window. `queue: nil` posts synchronously on the posting
    /// thread (always main here), keeping `lastPageIndex` fresh for the
    /// next button press.
    func attachBoundsObserver(to scrollView: NSScrollView) {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleBoundsChange()
            }
        }
    }

    private func handleBoundsChange() {
        guard let sv = scrollView else { return }

        // Magnification changes (pinch, double-click, programmatic) move the
        // clip bounds, so this observer is where we learn about them across
        // every layout. Push the live value into ViewerController so the
        // toolbar's fit-mode highlight tracks the user's zoom in real time —
        // the rest of this method only handles vertical-strip scroll work.
        viewerController?.currentMagnification = sv.magnification

        guard lastLayout.isContinuous,
              let stack = sv.documentView as? ImageStackView else { return }
        let visibleRect = sv.documentVisibleRect

        // Page-index callback is suppressed during programmatic scroll so
        // the model doesn't feedback-loop on its own jump.
        if !isProgrammaticallyScrolling {
            let centerY = visibleRect.midY
            let visibleIndex = stack.pageIndex(forViewportY: centerY)
            if visibleIndex != lastPageIndex {
                lastPageIndex = visibleIndex
                onPageIndexChanged(visibleIndex)
            }
        }

        // Visible-range callback always fires — lazy loading needs to populate
        // slots after auto-scroll to a restored position or after large jumps.
        let visibleRange = stack.pageIndexRange(visibleIn: visibleRect)
        if visibleRange != lastVisibleRange {
            lastVisibleRange = visibleRange
            onVisibleRangeChanged(visibleRange)
        }

        // Materialize NSImageViews for newly-visible pages, recycle ones
        // that scrolled out. Keeps the view tree small even on 1000-page
        // strips.
        stack.refreshVisibleViews(visibleRect: visibleRect)
    }
}
