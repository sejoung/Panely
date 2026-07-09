import AppKit

/// NSScrollView that adds ⌘+scroll = zoom centered at the cursor (the
/// standard macOS gesture), plain-scroll page turning in paged layouts (via
/// `WheelPageTurnEngine`), and never grabs first-responder so SwiftUI key
/// handling on the parent stays intact.
final class PanelyScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }

    /// Gates wheel-driven page turning. Set by `AppKitImageScroller` from the
    /// user preference AND the layout — always false in continuous/vertical
    /// mode, where scrolling *is* reading and must never be intercepted.
    var wheelPageTurnEnabled = false {
        didSet {
            // A layout/preference flip mid-gesture would otherwise leave the
            // engine holding half a gesture's state.
            if wheelPageTurnEnabled != oldValue {
                pageTurnEngine = WheelPageTurnEngine()
            }
        }
    }

    /// Fires when the engine commits a turn. Wired up through the SwiftUI
    /// bridge to the view model's `advanceForward()` / `goBackward()`.
    var onPageTurn: ((PageTurnDirection) -> Void)?

    private var pageTurnEngine = WheelPageTurnEngine()

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

    static func zoomCenter(
        eventLocationInWindow: NSPoint,
        documentView: NSView?
    ) -> NSPoint {
        guard let documentView else { return eventLocationInWindow }
        return documentView.convert(eventLocationInWindow, from: nil)
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
            let center = Self.zoomCenter(
                eventLocationInWindow: event.locationInWindow,
                documentView: documentView
            )
            setMagnification(target, centeredAt: center)
            return
        }
        if wheelPageTurnEnabled, documentView != nil, let onPageTurn {
            switch pageTurnEngine.decide(pageTurnEventInfo(for: event)) {
            case .turn(let direction):
                onPageTurn(direction)
                return
            case .swallow:
                return
            case .pan:
                break
            }
        }
        super.scrollWheel(with: event)
    }

    // MARK: - Wheel page-turn plumbing

    private func pageTurnEventInfo(for event: NSEvent) -> WheelPageTurnEngine.EventInfo {
        let state = Self.verticalScrollState(
            visibleRect: documentVisibleRect,
            documentBounds: documentView?.bounds ?? .zero
        )
        return WheelPageTurnEngine.EventInfo(
            deltaY: event.scrollingDeltaY,
            phase: Self.enginePhase(from: event.phase),
            isMomentum: event.momentumPhase != [],
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            timestamp: event.timestamp,
            canScrollVertically: state.canScroll,
            atTop: state.atTop,
            atBottom: state.atBottom
        )
    }

    /// Vertical pan/edge state in document coordinates. `documentVisibleRect`
    /// already accounts for magnification, and `ImageStackView` is flipped, so
    /// `minY` is the visual top. When the page fits the viewport the centering
    /// clip view over-extends the visible rect past both document edges, which
    /// correctly reads as at-top AND at-bottom. The 1-pt epsilon absorbs
    /// magnification rounding so a page resting on an edge still counts as
    /// pinned to it.
    static func verticalScrollState(
        visibleRect: NSRect,
        documentBounds: NSRect
    ) -> (canScroll: Bool, atTop: Bool, atBottom: Bool) {
        let epsilon: CGFloat = 1.0
        let canScroll = documentBounds.height - visibleRect.height > epsilon
        let atTop = visibleRect.minY <= documentBounds.minY + epsilon
        let atBottom = visibleRect.maxY >= documentBounds.maxY - epsilon
        return (canScroll, atTop, atBottom)
    }

    static func enginePhase(from phase: NSEvent.Phase) -> WheelPageTurnEngine.Phase {
        if phase.contains(.began) || phase.contains(.mayBegin) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
        return .none
    }
}
