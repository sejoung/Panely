import AppKit

/// NSScrollView that adds ⌘+scroll = zoom centered at the cursor (the
/// standard macOS gesture) and never grabs first-responder so SwiftUI key
/// handling on the parent stays intact.
final class PanelyScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }

    /// Sensitivity of cmd-scroll zoom. ~1% per scroll-delta unit feels right
    /// for both trackpad inertia and discrete mouse-wheel notches.
    static let zoomScrollSensitivity: CGFloat = 0.01

    static func zoomTarget(
        currentMagnification: CGFloat,
        scrollDelta: CGFloat,
        minMag: CGFloat,
        maxMag: CGFloat
    ) -> CGFloat {
        let factor = 1.0 + (scrollDelta * zoomScrollSensitivity)
        return min(max(currentMagnification * factor, minMag), maxMag)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && allowsMagnification {
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return }
            let target = Self.zoomTarget(
                currentMagnification: magnification,
                scrollDelta: delta,
                minMag: minMagnification,
                maxMag: maxMagnification
            )
            let center = convert(event.locationInWindow, from: nil)
            setMagnification(target, centeredAt: center)
            return
        }
        super.scrollWheel(with: event)
    }
}
