import AppKit

/// Imperative remote-control for the AppKit scroll view that powers the
/// reader. Owned by `ReaderScene`, attached to the `NSScrollView` inside
/// `AppKitImageScroller.makeNSView`. Lets toolbar buttons / menu commands
/// drive zoom without ReaderViewModel having to know about AppKit.
@MainActor
@Observable
final class ViewerController {
    private weak var scrollView: NSScrollView?

    /// Magnification corresponding to the current fit mode (fit-screen or
    /// fit-width). Set by `AppKitImageScroller.applyFit` after every fit
    /// recompute so `resetZoom()` snaps back to the right baseline.
    var baseMagnification: CGFloat = 1.0

    /// Most recently observed `scrollView.magnification`. Updated by the
    /// coordinator on bounds change (covers programmatic, pinch, and
    /// double-click zoom) and by the zoom methods below. The toolbar reads
    /// `isAtFit` derived from this so the fit-mode buttons un-highlight
    /// the moment the user zooms away from the fit baseline.
    var currentMagnification: CGFloat = 1.0

    /// True when the scroll view's magnification matches the current fit
    /// baseline (within float tolerance). The toolbar uses this to gate
    /// the fit-mode button highlight — picking a fit mode then zooming in
    /// should drop the highlight, since the user is no longer "at fit."
    var isAtFit: Bool {
        abs(currentMagnification - baseMagnification) < 0.001
    }

    private let zoomStep: CGFloat = 1.25

    func attach(scrollView: NSScrollView) {
        // Idempotent: `AppKitImageScroller.updateNSView` re-invokes this on
        // every SwiftUI tick. Re-seeding `currentMagnification` from the raw
        // scroll view each time would clobber a value the coordinator just
        // pushed mid-gesture (dropping the toolbar's fit highlight). Only
        // (re)seed when the underlying scroll view actually changes.
        guard self.scrollView !== scrollView else { return }
        self.scrollView = scrollView
        currentMagnification = scrollView.magnification
    }

    func zoomIn() {
        guard let sv = scrollView else { return }
        let target = min(sv.magnification * zoomStep, sv.maxMagnification)
        let center = NSPoint(x: sv.documentVisibleRect.midX, y: sv.documentVisibleRect.midY)
        sv.setMagnification(target, centeredAt: center)
        currentMagnification = sv.magnification
    }

    func zoomOut() {
        guard let sv = scrollView else { return }
        let target = max(sv.magnification / zoomStep, sv.minMagnification)
        let center = NSPoint(x: sv.documentVisibleRect.midX, y: sv.documentVisibleRect.midY)
        sv.setMagnification(target, centeredAt: center)
        currentMagnification = sv.magnification
    }

    func resetZoom() {
        guard let sv = scrollView else { return }
        sv.magnification = baseMagnification
        currentMagnification = sv.magnification
    }
}
