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

    private let zoomStep: CGFloat = 1.25

    func attach(scrollView: NSScrollView) {
        self.scrollView = scrollView
    }

    func zoomIn() {
        guard let sv = scrollView else { return }
        let target = min(sv.magnification * zoomStep, sv.maxMagnification)
        let center = NSPoint(x: sv.documentVisibleRect.midX, y: sv.documentVisibleRect.midY)
        sv.setMagnification(target, centeredAt: center)
    }

    func zoomOut() {
        guard let sv = scrollView else { return }
        let target = max(sv.magnification / zoomStep, sv.minMagnification)
        let center = NSPoint(x: sv.documentVisibleRect.midX, y: sv.documentVisibleRect.midY)
        sv.setMagnification(target, centeredAt: center)
    }

    func resetZoom() {
        guard let sv = scrollView else { return }
        sv.magnification = baseMagnification
    }
}
