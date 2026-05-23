import AppKit
import SwiftUI

/// Transparent top strip overlaid on the viewer. Catches window-drag,
/// double-click-to-zoom, and cursor styling for the area above the comic
/// while leaving the traffic-light buttons fully usable.
struct TitleBarPassthrough: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TitleBarPassthroughView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class TitleBarPassthroughView: NSView {
    /// Width (in window coords, measured from the leading edge) reserved for
    /// the close / minimize / zoom buttons. Standard macOS metrics place the
    /// three buttons plus their margins inside the leading ~78pt.
    private static let trafficLightInset: CGFloat = 78

    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Re-run `updateTrackingAreas` when our window-position shifts (e.g.,
        // library sidebar pin toggle) so the traffic-light exclusion stays
        // accurate. Only our own frame changes fire this — a window-resize
        // that keeps our frame the same doesn't need a re-run.
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: self
        )
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleFrameDidChange() {
        updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Position in window coords isn't settled until we're actually in a
        // window, so a freshly installed passthrough needs one more pass.
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }

        // Split the 28pt strip into two adjacent tracking areas so that
        // `cursorUpdate` fires when the cursor moves *between* them — a
        // single area would only fire on initial entry, leaving the
        // openHand cursor stuck over the traffic-light buttons when the
        // cursor drifts leftward. Which region the cursor is in is decided
        // at event-time from `locationInWindow`, so this also works when
        // the passthrough is moved by sidebar pin toggles.
        let windowMinX = convert(bounds, to: nil).minX
        let leftExclude = max(0, Self.trafficLightInset - windowMinX)

        let options: NSTrackingArea.Options = [
            .cursorUpdate,
            .activeInKeyWindow,
        ]

        if leftExclude > 0 {
            let trafficLightRect = NSRect(
                x: 0,
                y: 0,
                width: leftExclude,
                height: bounds.height
            )
            addTrackingArea(NSTrackingArea(
                rect: trafficLightRect,
                options: options,
                owner: self,
                userInfo: nil
            ))
        }

        let handRect = NSRect(
            x: leftExclude,
            y: 0,
            width: max(0, bounds.width - leftExclude),
            height: bounds.height
        )
        if handRect.width > 0 {
            addTrackingArea(NSTrackingArea(
                rect: handRect,
                options: options,
                owner: self,
                userInfo: nil
            ))
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        // Decide the cursor from the current window-space X — this stays
        // correct regardless of which of the two tracking areas fired, and
        // it self-corrects if the passthrough has been moved since the
        // tracking areas were recomputed.
        if event.locationInWindow.x <= Self.trafficLightInset {
            NSCursor.arrow.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            switch action {
            case "Minimize":
                window?.performMiniaturize(nil)
            case "None":
                break
            default:
                window?.performZoom(nil)
            }
            return
        }
        super.mouseDown(with: event)
    }
}
