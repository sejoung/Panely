import AppKit

/// Clip view that recenters its bounds when the document is smaller than
/// the viewport on either axis. Without this, a fit-screen page on a wide
/// window would stick to the leading edge instead of sitting in the middle.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }

        let docFrame = documentView.frame

        if rect.size.width > docFrame.size.width {
            rect.origin.x = docFrame.midX - rect.size.width / 2
        }
        if rect.size.height > docFrame.size.height {
            rect.origin.y = docFrame.midY - rect.size.height / 2
        }
        return rect
    }
}
