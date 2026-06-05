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
    var lastSeriesIdentity: String = ""
    var lastFitMode: FitMode = .fitScreen
    var lastLayout: PageLayout = .single
    var lastPageIndex: Int = -1
    var lastVisibleRange: Range<Int> = 0..<0
    var isProgrammaticallyScrolling: Bool = false
    var autoFitOnResize: Bool = true

    /// Fit baseline magnification. The single stored copy lives on
    /// `ViewerController` — which also needs it for `resetZoom` and the
    /// toolbar's reactive `isAtFit` — so the coordinator reads and writes it
    /// through there rather than keeping a second copy in sync by hand. The
    /// private fallback is used only when no controller is attached (SwiftUI
    /// previews / unit tests without a toolbar); production always has one, so
    /// there is exactly one source of truth at runtime.
    var baseMagnification: CGFloat {
        get { viewerController?.baseMagnification ?? fallbackBaseMagnification }
        set {
            if let viewerController {
                viewerController.baseMagnification = newValue
            } else {
                fallbackBaseMagnification = newValue
            }
        }
    }
    private var fallbackBaseMagnification: CGFloat = 1.0

    /// False until the first valid `applyFit` runs. The very first fit must
    /// snap to the computed magnification unconditionally — if it happened to
    /// run while `scrollView.magnification` was at a transient default that
    /// differs from `baseMagnification`, the `userHasZoomed` heuristic would
    /// spuriously read `true` and suppress the fit, leaving the page rendered
    /// at the wrong (or zero) magnification.
    var hasAppliedInitialFit: Bool = false

    /// One-shot fit-relative zoom to apply on the next valid fit after a book
    /// switch. Captured when the book (`identity`) changes — `nil` outside that
    /// window. `applyFit` consumes it: `magnification = factor × newFit`, so a
    /// value of 1.0 means "snap to the new book's fit" and e.g. 2.0 means
    /// "keep showing it at twice the fit, like the previous book". Held until
    /// the first fit with a valid document size (the empty-strip ticks during
    /// a vertical rebuild early-return before consuming it), which is why it's
    /// a stored one-shot rather than gated on the transient `identityChanged`.
    var pendingZoomFactor: CGFloat?

    /// Session memory of each series' last manual zoom, as a fit-relative
    /// factor. Lets leaving a series and returning (within the same session)
    /// restore that series' zoom, while a series you left at fit — or never
    /// zoomed — comes back at fit. Lives on the coordinator, which now persists
    /// across book switches (the viewer stays mounted), and is intentionally
    /// not persisted to disk: zoom carry-over is session-scoped.
    var sessionZoomBySeriesID: [String: CGFloat] = [:]

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
        reinstall(&frameObserver, name: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] in
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

    /// Watch the clip view for scroll changes so we can update the model's
    /// page index, the visible-range subscription, and recycle pages out of
    /// the visible window. `queue: nil` posts synchronously on the posting
    /// thread (always main here), keeping `lastPageIndex` fresh for the
    /// next button press.
    func attachBoundsObserver(to scrollView: NSScrollView) {
        reinstall(&boundsObserver, name: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil) { [weak self] in
            self?.handleBoundsChange()
        }
    }

    /// Replace `token`'s observer: tear down any prior registration (so SwiftUI
    /// recreating the representable can't double-register → double-fire), then
    /// add a new main-actor observer. `handler` runs inside
    /// `MainActor.assumeIsolated` — notifications for these views post on the
    /// main thread, and `addObserver` is `nonisolated`.
    private func reinstall(
        _ token: inout NSObjectProtocol?,
        name: NSNotification.Name,
        object: Any?,
        queue: OperationQueue?,
        handler: @escaping @MainActor () -> Void
    ) {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        token = NotificationCenter.default.addObserver(forName: name, object: object, queue: queue) { _ in
            MainActor.assumeIsolated {
                handler()
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
