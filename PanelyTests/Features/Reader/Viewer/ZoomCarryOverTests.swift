import Testing
import Foundation
import AppKit
@testable import Panely

/// Session, series-bounded zoom carry-over. When the user manually zooms
/// (escapes fit) and moves to a sibling volume of the same series, the page
/// keeps the same on-screen scale (fit-relative factor). Jumping to a
/// different series — or never having zoomed — snaps the next book to its own
/// fit. Two layers are tested:
///   - `zoomCarryOverFactor`: the pure decision (what factor to carry)
///   - `applyFit` consuming `pendingZoomFactor`: applying `factor × newFit`
@MainActor
struct ZoomCarryOverTests {

    // MARK: - Decision policy (with per-series session memory)

    @Test func sameSeriesEscapedZoomCarriesTheRatio() {
        // Was at 2× the fit baseline, staying in the same series → carry 2.0.
        var memory: [String: CGFloat] = [:]
        let factor = AppKitImageScroller.resolveSeriesZoom(
            previousSeriesID: "A", newSeriesID: "A",
            baseMagnification: 0.4, magnification: 0.8, memory: &memory
        )
        #expect(abs(factor - 2.0) < 0.0001)
    }

    @Test func sameSeriesAtFitStaysAtFit() {
        var memory: [String: CGFloat] = [:]
        let factor = AppKitImageScroller.resolveSeriesZoom(
            previousSeriesID: "A", newSeriesID: "A",
            baseMagnification: 0.4, magnification: 0.4, memory: &memory
        )
        #expect(abs(factor - 1.0) < 0.0001)
    }

    @Test func differentSeriesWithoutMemoryResetsToFit() {
        // Escaped zoom (2×) but jumping to a series we've never zoomed → fit.
        var memory: [String: CGFloat] = [:]
        let factor = AppKitImageScroller.resolveSeriesZoom(
            previousSeriesID: "A", newSeriesID: "B",
            baseMagnification: 0.4, magnification: 0.8, memory: &memory
        )
        #expect(abs(factor - 1.0) < 0.0001)
        // Leaving A while zoomed records A's factor for a later return.
        #expect(memory["A"].map { abs($0 - 2.0) < 0.0001 } == true)
    }

    @Test func returningToASeriesRestoresItsRememberedZoom() {
        // A→B (records A=2.0), then B→A restores 2.0 even though B was at fit.
        var memory: [String: CGFloat] = [:]
        _ = AppKitImageScroller.resolveSeriesZoom(
            previousSeriesID: "A", newSeriesID: "B",
            baseMagnification: 0.4, magnification: 0.8, memory: &memory // leave A at 2×
        )
        let back = AppKitImageScroller.resolveSeriesZoom(
            previousSeriesID: "B", newSeriesID: "A",
            baseMagnification: 0.5, magnification: 0.5, memory: &memory // B was at fit
        )
        #expect(abs(back - 2.0) < 0.0001)
    }

    @Test func leavingASeriesAtFitClearsItsMemory() {
        // A was zoomed earlier (memory has it), but the user returns to fit in A
        // and then leaves → A's slot clears, so the next return lands at fit.
        var memory: [String: CGFloat] = ["A": 2.0]
        _ = AppKitImageScroller.resolveSeriesZoom(
            previousSeriesID: "A", newSeriesID: "B",
            baseMagnification: 0.4, magnification: 0.4, memory: &memory // A now at fit
        )
        #expect(memory["A"] == nil)
    }

    @Test func zeroBaselineIsTreatedAsAtFit() {
        // Degenerate baseline (no valid fit yet) must not divide-by-zero.
        var memory: [String: CGFloat] = [:]
        let factor = AppKitImageScroller.resolveSeriesZoom(
            previousSeriesID: "A", newSeriesID: "A",
            baseMagnification: 0, magnification: 0.8, memory: &memory
        )
        #expect(abs(factor - 1.0) < 0.0001)
    }

    // MARK: - applyFit consuming the pending factor

    @Test func applyFitConsumesPendingFactorAsFitRelativeZoom() {
        // New book fit-width = 0.4 (2000px page in an 800px viewport). A
        // pending factor of 2.0 must land the page at 2× its OWN fit = 0.8,
        // and adopt 0.4 as the new baseline so reset/double-click are correct.
        let scrollView = makeScrollView(width: 800, height: 600)
        let book = NSView(frame: NSRect(x: 0, y: 0, width: 2000, height: 3000))
        scrollView.documentView = book
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        coordinator.hasAppliedInitialFit = true
        coordinator.pendingZoomFactor = 2.0

        AppKitImageScroller.applyFit(
            scrollView: scrollView, coordinator: coordinator, fitMode: .fitWidth, force: false
        )

        let newFit = FitCalculator.magnification(
            docSize: book.frame.size, viewport: scrollView.contentSize, fitMode: .fitWidth
        )
        #expect(abs(scrollView.magnification - newFit * 2.0) < 0.001)
        #expect(abs(coordinator.baseMagnification - newFit) < 0.001)
        #expect(coordinator.pendingZoomFactor == nil) // one-shot, consumed
    }

    @Test func applyFitWithPendingFactorOneSnapsToNewFit() {
        // Factor 1.0 (cross-series or was-at-fit) → magnification == new fit.
        let scrollView = makeScrollView(width: 800, height: 600)
        let book = NSView(frame: NSRect(x: 0, y: 0, width: 2000, height: 3000))
        scrollView.documentView = book
        scrollView.layoutSubtreeIfNeeded()
        scrollView.magnification = 5.0 // stale zoom from a previous book

        let coordinator = AppKitScrollerCoordinator()
        coordinator.hasAppliedInitialFit = true
        coordinator.pendingZoomFactor = 1.0

        AppKitImageScroller.applyFit(
            scrollView: scrollView, coordinator: coordinator, fitMode: .fitWidth, force: false
        )

        let newFit = FitCalculator.magnification(
            docSize: book.frame.size, viewport: scrollView.contentSize, fitMode: .fitWidth
        )
        #expect(abs(scrollView.magnification - newFit) < 0.001)
        #expect(coordinator.pendingZoomFactor == nil)
    }

    @Test func pendingFactorClampsToMagnificationCeiling() {
        // factor × fit beyond maxMagnification must clamp, not overshoot.
        let scrollView = makeScrollView(width: 800, height: 600)
        scrollView.maxMagnification = 3.0
        let book = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = book
        scrollView.layoutSubtreeIfNeeded()

        let coordinator = AppKitScrollerCoordinator()
        coordinator.hasAppliedInitialFit = true
        coordinator.pendingZoomFactor = 100.0

        AppKitImageScroller.applyFit(
            scrollView: scrollView, coordinator: coordinator, fitMode: .fitWidth, force: false
        )
        #expect(scrollView.magnification <= 3.0 + 0.0001)
    }

    private func makeScrollView(width: CGFloat, height: CGFloat) -> NSScrollView {
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        sv.allowsMagnification = true
        sv.minMagnification = 0.01
        sv.maxMagnification = 10.0
        sv.drawsBackground = false
        return sv
    }
}
