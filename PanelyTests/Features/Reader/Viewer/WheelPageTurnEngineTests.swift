import Testing
import Foundation
import AppKit
@testable import Panely

/// Builds `EventInfo` snapshots with reader-typical defaults so each test
/// states only what it cares about.
private func event(
    deltaY: CGFloat = 0,
    phase: WheelPageTurnEngine.Phase = .none,
    isMomentum: Bool = false,
    hasPreciseDeltas: Bool = true,
    timestamp: TimeInterval = 0,
    canScrollVertically: Bool = false,
    atTop: Bool = true,
    atBottom: Bool = true
) -> WheelPageTurnEngine.EventInfo {
    WheelPageTurnEngine.EventInfo(
        deltaY: deltaY,
        phase: phase,
        isMomentum: isMomentum,
        hasPreciseDeltas: hasPreciseDeltas,
        timestamp: timestamp,
        canScrollVertically: canScrollVertically,
        atTop: atTop,
        atBottom: atBottom
    )
}

struct WheelPageTurnEngineTests {

    private static let threshold = WheelPageTurnEngine.preciseTurnThreshold
    private static let cooldown = WheelPageTurnEngine.discreteCooldown
    private static let resetGap = WheelPageTurnEngine.phaselessResetInterval

    // MARK: - Trackpad (phased, precise): fit-to-viewport page

    @Test func trackpadSwipeDownOnFitPageTurnsForwardOnce() {
        var engine = WheelPageTurnEngine()
        #expect(engine.decide(event(phase: .began)) == .pan)

        // Accumulate downward (negative deltaY) past the threshold.
        #expect(engine.decide(event(deltaY: -Self.threshold / 2, phase: .changed)) == .swallow)
        #expect(engine.decide(event(deltaY: -Self.threshold / 2, phase: .changed)) == .turn(.forward))

        // The rest of the gesture is latched — no double turns.
        #expect(engine.decide(event(deltaY: -Self.threshold, phase: .changed)) == .swallow)
        #expect(engine.decide(event(phase: .ended)) == .swallow)
    }

    @Test func trackpadSwipeUpOnFitPageTurnsBackward() {
        var engine = WheelPageTurnEngine()
        _ = engine.decide(event(phase: .began))
        #expect(engine.decide(event(deltaY: Self.threshold, phase: .changed)) == .turn(.backward))
    }

    @Test func trackpadSubThresholdSwipeNeverTurns() {
        var engine = WheelPageTurnEngine()
        _ = engine.decide(event(phase: .began))
        #expect(engine.decide(event(deltaY: -Self.threshold + 1, phase: .changed)) == .swallow)
        #expect(engine.decide(event(phase: .ended)) == .pan)
    }

    @Test func momentumAfterTurnIsSwallowedSoInertiaCannotSkipPages() {
        var engine = WheelPageTurnEngine()
        _ = engine.decide(event(phase: .began))
        #expect(engine.decide(event(deltaY: -Self.threshold, phase: .changed)) == .turn(.forward))
        _ = engine.decide(event(phase: .ended))

        #expect(engine.decide(event(deltaY: -40, phase: .changed, isMomentum: true)) == .swallow)
        #expect(engine.decide(event(deltaY: -200, phase: .changed, isMomentum: true)) == .swallow)
    }

    @Test func nextGestureAfterTurnCanTurnAgain() {
        var engine = WheelPageTurnEngine()
        _ = engine.decide(event(phase: .began))
        #expect(engine.decide(event(deltaY: -Self.threshold, phase: .changed)) == .turn(.forward))

        _ = engine.decide(event(phase: .began))
        #expect(engine.decide(event(deltaY: -Self.threshold, phase: .changed)) == .turn(.forward))
    }

    // MARK: - Trackpad: zoomed page (pannable content)

    @Test func gestureStartingMidContentOnlyPansEvenWhenItReachesTheEdge() {
        var engine = WheelPageTurnEngine()
        _ = engine.decide(event(phase: .began))
        // First movement happens away from both edges → whole gesture pans.
        #expect(engine.decide(event(
            deltaY: -30, phase: .changed,
            canScrollVertically: true, atTop: false, atBottom: false
        )) == .pan)
        // Even a huge later delta arriving pinned at the bottom stays a pan.
        #expect(engine.decide(event(
            deltaY: -10 * Self.threshold, phase: .changed,
            canScrollVertically: true, atTop: false, atBottom: true
        )) == .pan)
        // …and so does its momentum.
        #expect(engine.decide(event(
            deltaY: -Self.threshold, phase: .changed, isMomentum: true,
            canScrollVertically: true, atTop: false, atBottom: true
        )) == .pan)
    }

    @Test func gestureStartingPinnedAtBottomScrollingDownTurnsForward() {
        var engine = WheelPageTurnEngine()
        _ = engine.decide(event(phase: .began))
        #expect(engine.decide(event(
            deltaY: -Self.threshold, phase: .changed,
            canScrollVertically: true, atTop: false, atBottom: true
        )) == .turn(.forward))
    }

    @Test func gestureStartingPinnedAtTopScrollingUpTurnsBackward() {
        var engine = WheelPageTurnEngine()
        _ = engine.decide(event(phase: .began))
        #expect(engine.decide(event(
            deltaY: Self.threshold, phase: .changed,
            canScrollVertically: true, atTop: true, atBottom: false
        )) == .turn(.backward))
    }

    @Test func gestureStartingAtBottomScrollingUpPansBackIntoThePage() {
        var engine = WheelPageTurnEngine()
        _ = engine.decide(event(phase: .began))
        // Up-scroll at the bottom edge of a pannable page: panning absorbs it.
        #expect(engine.decide(event(
            deltaY: Self.threshold, phase: .changed,
            canScrollVertically: true, atTop: false, atBottom: true
        )) == .pan)
    }

    @Test func reversingAnEligibleGestureHandsItBackToPanning() {
        var engine = WheelPageTurnEngine()
        _ = engine.decide(event(phase: .began))
        #expect(engine.decide(event(
            deltaY: -20, phase: .changed,
            canScrollVertically: true, atTop: false, atBottom: true
        )) == .swallow)
        // Net movement flips positive (upward) → gesture pans from here on.
        #expect(engine.decide(event(
            deltaY: 30, phase: .changed,
            canScrollVertically: true, atTop: false, atBottom: true
        )) == .pan)
        #expect(engine.decide(event(
            deltaY: -10 * Self.threshold, phase: .changed,
            canScrollVertically: true, atTop: false, atBottom: true
        )) == .pan)
    }

    // MARK: - Discrete mouse wheel

    @Test func wheelNotchAtEdgeTurnsImmediately() {
        var engine = WheelPageTurnEngine()
        #expect(engine.decide(event(
            deltaY: -1, hasPreciseDeltas: false, timestamp: 10
        )) == .turn(.forward))
    }

    @Test func wheelNotchUpAtTopTurnsBackward() {
        var engine = WheelPageTurnEngine()
        #expect(engine.decide(event(
            deltaY: 1, hasPreciseDeltas: false, timestamp: 10,
            canScrollVertically: true, atTop: true, atBottom: false
        )) == .turn(.backward))
    }

    @Test func wheelNotchMidContentPans() {
        var engine = WheelPageTurnEngine()
        #expect(engine.decide(event(
            deltaY: -1, hasPreciseDeltas: false, timestamp: 10,
            canScrollVertically: true, atTop: false, atBottom: false
        )) == .pan)
    }

    @Test func wheelCooldownLimitsTurnRate() {
        var engine = WheelPageTurnEngine()
        #expect(engine.decide(event(
            deltaY: -1, hasPreciseDeltas: false, timestamp: 10
        )) == .turn(.forward))
        // Inside the cooldown window: consumed, not turned.
        #expect(engine.decide(event(
            deltaY: -1, hasPreciseDeltas: false, timestamp: 10 + Self.cooldown / 2
        )) == .swallow)
        // Past the cooldown: turns again.
        #expect(engine.decide(event(
            deltaY: -1, hasPreciseDeltas: false, timestamp: 10 + Self.cooldown
        )) == .turn(.forward))
    }

    @Test func zeroDeltaEventsPan() {
        var engine = WheelPageTurnEngine()
        #expect(engine.decide(event(deltaY: 0, hasPreciseDeltas: false)) == .pan)
        #expect(engine.decide(event(deltaY: 0, phase: .changed)) == .pan)
    }

    // MARK: - Precise deltas without phases (e.g. some mice)

    @Test func phaselessAccumulatesAcrossEventsAndLatchesAfterTurn() {
        var engine = WheelPageTurnEngine()
        #expect(engine.decide(event(deltaY: -Self.threshold / 2, timestamp: 10.00)) == .swallow)
        #expect(engine.decide(event(deltaY: -Self.threshold / 2, timestamp: 10.05)) == .turn(.forward))
        // Still inside the same burst: latched.
        #expect(engine.decide(event(deltaY: -Self.threshold, timestamp: 10.10)) == .swallow)
    }

    @Test func phaselessQuietGapResetsAccumulationAndLatch() {
        var engine = WheelPageTurnEngine()
        #expect(engine.decide(event(deltaY: -Self.threshold, timestamp: 10)) == .turn(.forward))
        // After a pause longer than the reset gap, a new burst can turn again.
        let later = 10 + Self.resetGap + 0.01
        #expect(engine.decide(event(deltaY: -Self.threshold, timestamp: later)) == .turn(.forward))
    }

    @Test func phaselessMidContentPansAndDropsAccumulation() {
        var engine = WheelPageTurnEngine()
        #expect(engine.decide(event(
            deltaY: -Self.threshold, timestamp: 10,
            canScrollVertically: true, atTop: false, atBottom: false
        )) == .pan)
    }
}

// MARK: - Scroll-view geometry → engine inputs

@MainActor
struct VerticalScrollStateTests {

    @Test func fitContentReadsAsUnscrollableAndAtBothEdges() {
        // Centering clip view over-extends the visible rect past the document.
        let state = PanelyScrollView.verticalScrollState(
            visibleRect: NSRect(x: 0, y: -50, width: 800, height: 700),
            documentBounds: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        #expect(state.canScroll == false)
        #expect(state.atTop == true)
        #expect(state.atBottom == true)
    }

    @Test func tallContentScrolledToMiddleIsAtNeitherEdge() {
        let state = PanelyScrollView.verticalScrollState(
            visibleRect: NSRect(x: 0, y: 500, width: 800, height: 600),
            documentBounds: NSRect(x: 0, y: 0, width: 800, height: 2000)
        )
        #expect(state.canScroll == true)
        #expect(state.atTop == false)
        #expect(state.atBottom == false)
    }

    @Test func tallContentAtTopEdge() {
        let state = PanelyScrollView.verticalScrollState(
            visibleRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            documentBounds: NSRect(x: 0, y: 0, width: 800, height: 2000)
        )
        #expect(state.atTop == true)
        #expect(state.atBottom == false)
    }

    @Test func tallContentAtBottomEdgeWithinEpsilon() {
        // 0.5-pt shy of the exact bottom — magnification rounding must still
        // count as pinned.
        let state = PanelyScrollView.verticalScrollState(
            visibleRect: NSRect(x: 0, y: 1399.5, width: 800, height: 600),
            documentBounds: NSRect(x: 0, y: 0, width: 800, height: 2000)
        )
        #expect(state.atTop == false)
        #expect(state.atBottom == true)
    }

    @Test func phaseMappingCollapsesNSEventPhases() {
        #expect(PanelyScrollView.enginePhase(from: .mayBegin) == .began)
        #expect(PanelyScrollView.enginePhase(from: .began) == .began)
        #expect(PanelyScrollView.enginePhase(from: .changed) == .changed)
        #expect(PanelyScrollView.enginePhase(from: .ended) == .ended)
        #expect(PanelyScrollView.enginePhase(from: .cancelled) == .ended)
        #expect(PanelyScrollView.enginePhase(from: []) == WheelPageTurnEngine.Phase.none)
    }
}
