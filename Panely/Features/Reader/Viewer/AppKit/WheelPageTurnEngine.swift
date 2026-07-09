import Foundation

/// Direction of a wheel-driven page turn, in reading order. The viewer maps
/// `forward`/`backward` onto the view model's `advanceForward()` /
/// `goBackward()`, so RTL direction and volume-boundary cards behave exactly
/// like the arrow keys.
enum PageTurnDirection: Equatable {
    case forward
    case backward
}

/// Decides, event by event, whether a plain scroll-wheel / trackpad scroll in
/// a paged layout should turn the page, pan the content, or be consumed.
/// Pure state machine over `EventInfo` snapshots (no NSEvent dependency) so
/// every device quirk is unit-testable.
///
/// The rules it encodes:
/// - Scrolling only turns a page when panning can't absorb it: the page fits
///   the viewport, or it's already pinned at the edge the scroll pushes past
///   (down at the bottom → forward, up at the top → backward).
/// - Trackpads (phased, precise deltas) turn at most **one page per gesture**:
///   the gesture must *begin* against a blocked edge, cross an accumulated
///   distance threshold, and then latch — its remaining events, including all
///   momentum, are swallowed so inertia never skips extra pages or pans the
///   freshly-turned page.
/// - Momentum from a gesture that panned (didn't turn) keeps panning normally.
/// - Discrete mouse wheels (no phases, line deltas) turn one page per notch,
///   rate-limited by a cooldown so a fast flick doesn't riffle the book.
/// - Precise-delta devices that report no phases fall back to accumulation
///   with a quiet-gap reset, plus the same one-turn latch until a pause.
struct WheelPageTurnEngine {
    /// What the scroll view should do with the event just examined.
    enum Action: Equatable {
        /// Forward to `super.scrollWheel` — normal panning / elasticity.
        case pan
        /// Consume the event without turning (mid-accumulation, latched
        /// leftovers, cooldown). Keeps a blocked edge from rubber-banding
        /// while a turn is charging up.
        case swallow
        case turn(PageTurnDirection)
    }

    /// Gesture phase, collapsed from `NSEvent.Phase` (`mayBegin`/`began` →
    /// `began`, `cancelled` → `ended`; empty → `none` for phase-less devices).
    enum Phase {
        case began
        case changed
        case ended
        case none
    }

    /// Device + geometry snapshot for one `scrollWheel` event. Geometry is in
    /// document coordinates (flipped, `minY` = visual top), so it stays
    /// magnification-correct.
    struct EventInfo {
        var deltaY: CGFloat
        var phase: Phase
        var isMomentum: Bool
        var hasPreciseDeltas: Bool
        /// Event timestamp (seconds, monotonic — `NSEvent.timestamp`). Used
        /// for the discrete cooldown and the phase-less quiet-gap reset.
        var timestamp: TimeInterval
        /// True when the document is taller than the viewport, i.e. vertical
        /// panning could still absorb scroll input somewhere.
        var canScrollVertically: Bool
        var atTop: Bool
        var atBottom: Bool
    }

    /// Accumulated trackpad travel (in points) required to commit a turn.
    /// High enough that resting fingers or a stray twitch at the edge don't
    /// flip pages, low enough that a deliberate short swipe does.
    static let preciseTurnThreshold: CGFloat = 60

    /// Minimum spacing between discrete-wheel turns. One notch always turns
    /// immediately; this only limits how fast a sustained spin riffles pages.
    static let discreteCooldown: TimeInterval = 0.3

    /// Quiet gap that separates "gestures" on precise devices without phase
    /// reporting — a pause longer than this resets accumulation and re-arms
    /// the one-turn latch.
    static let phaselessResetInterval: TimeInterval = 0.25

    private enum Eligibility {
        /// Gesture started; waiting for the first non-zero delta to lock a
        /// direction and check the edge it pushes against.
        case undecided
        /// Gesture began against a blocked edge — accumulate toward a turn
        /// in this direction only.
        case eligible(PageTurnDirection)
        /// Gesture began where panning can absorb it (or reversed away) —
        /// the whole gesture pans, even if it later reaches an edge. Turning
        /// requires a fresh swipe, so overshooting a long page never flips it.
        case ineligible
    }

    private var accumulated: CGFloat = 0
    /// True once this gesture turned a page; cleared by the next `began`
    /// (or, phase-less, by a quiet gap).
    private var latched = false
    private var eligibility: Eligibility = .undecided
    private var lastTurnTime: TimeInterval = -.infinity
    private var lastEventTime: TimeInterval = -.infinity

    mutating func decide(_ event: EventInfo) -> Action {
        guard event.hasPreciseDeltas else {
            return decideDiscrete(event)
        }
        if event.isMomentum {
            // Inertia inherits the gesture's verdict: a gesture that turned
            // must not let its leftovers pan the new page; one that panned
            // keeps its natural glide.
            return latched ? .swallow : .pan
        }
        switch event.phase {
        case .began:
            accumulated = 0
            latched = false
            eligibility = .undecided
            return .pan
        case .changed:
            return decideChanged(event)
        case .ended:
            return latched ? .swallow : .pan
        case .none:
            return decidePhaseless(event)
        }
    }

    // MARK: - Per-device paths

    private mutating func decideChanged(_ event: EventInfo) -> Action {
        if latched { return .swallow }

        if case .undecided = eligibility, event.deltaY != 0 {
            let direction = Self.direction(forDeltaY: event.deltaY)
            eligibility = Self.edgePermits(event, direction) ? .eligible(direction) : .ineligible
        }
        guard case .eligible(let direction) = eligibility else { return .pan }

        accumulated += event.deltaY
        // Net movement flipped against the locked direction — the user is
        // pulling back; hand the rest of the gesture to normal panning.
        let reversed = direction == .forward ? accumulated > 0 : accumulated < 0
        if reversed {
            eligibility = .ineligible
            return .pan
        }
        if Self.crossedThreshold(accumulated, direction: direction),
           Self.edgePermits(event, direction) {
            latched = true
            return .turn(direction)
        }
        return .swallow
    }

    private mutating func decidePhaseless(_ event: EventInfo) -> Action {
        guard event.deltaY != 0 else { return .pan }
        if event.timestamp - lastEventTime > Self.phaselessResetInterval {
            accumulated = 0
            latched = false
        }
        lastEventTime = event.timestamp
        if latched { return .swallow }

        let direction = Self.direction(forDeltaY: event.deltaY)
        guard Self.edgePermits(event, direction) else {
            accumulated = 0
            return .pan
        }
        accumulated += event.deltaY
        if Self.crossedThreshold(accumulated, direction: direction) {
            accumulated = 0
            latched = true
            return .turn(direction)
        }
        return .swallow
    }

    private mutating func decideDiscrete(_ event: EventInfo) -> Action {
        guard event.deltaY != 0 else { return .pan }
        let direction = Self.direction(forDeltaY: event.deltaY)
        guard Self.edgePermits(event, direction) else { return .pan }
        guard event.timestamp - lastTurnTime >= Self.discreteCooldown else { return .swallow }
        lastTurnTime = event.timestamp
        return .turn(direction)
    }

    // MARK: - Shared predicates

    /// AppKit's `scrollingDeltaY` is pre-adjusted for natural scrolling:
    /// negative = the reading gesture (content moves up / toward the end).
    private static func direction(forDeltaY deltaY: CGFloat) -> PageTurnDirection {
        deltaY < 0 ? .forward : .backward
    }

    /// A turn is allowed only where panning can't absorb the scroll: content
    /// that fits the viewport permits both directions; otherwise the scroll
    /// must push past the edge it's already pinned to.
    private static func edgePermits(_ event: EventInfo, _ direction: PageTurnDirection) -> Bool {
        guard event.canScrollVertically else { return true }
        return direction == .forward ? event.atBottom : event.atTop
    }

    private static func crossedThreshold(_ accumulated: CGFloat, direction: PageTurnDirection) -> Bool {
        direction == .forward
            ? accumulated <= -preciseTurnThreshold
            : accumulated >= preciseTurnThreshold
    }
}
