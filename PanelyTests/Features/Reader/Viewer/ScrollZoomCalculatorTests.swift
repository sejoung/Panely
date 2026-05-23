import Testing
import Foundation
import AppKit
@testable import Panely

@MainActor
struct ScrollZoomCalculatorTests {
    @Test func positiveDeltaIncreasesMagnification() {
        let target = PanelyScrollView.zoomTarget(
            currentMagnification: 1.0,
            scrollDelta: 10,
            minMag: 0.1,
            maxMag: 10
        )
        #expect(target > 1.0)
    }

    @Test func negativeDeltaDecreasesMagnification() {
        let target = PanelyScrollView.zoomTarget(
            currentMagnification: 1.0,
            scrollDelta: -10,
            minMag: 0.1,
            maxMag: 10
        )
        #expect(target < 1.0)
    }

    @Test func zeroDeltaReturnsSameMagnification() {
        let target = PanelyScrollView.zoomTarget(
            currentMagnification: 1.0,
            scrollDelta: 0,
            minMag: 0.1,
            maxMag: 10
        )
        #expect(abs(target - 1.0) < 0.0001)
    }

    @Test func clampsToMaxMagnification() {
        let target = PanelyScrollView.zoomTarget(
            currentMagnification: 9.5,
            scrollDelta: 1000,
            minMag: 0.1,
            maxMag: 10
        )
        #expect(target == 10)
    }

    @Test func clampsToMinMagnification() {
        let target = PanelyScrollView.zoomTarget(
            currentMagnification: 0.15,
            scrollDelta: -1000,
            minMag: 0.1,
            maxMag: 10
        )
        #expect(target == 0.1)
    }

    @Test func factorIsMultiplicative() {
        // Same delta from different starting points scales proportionally.
        let from1 = PanelyScrollView.zoomTarget(
            currentMagnification: 1.0, scrollDelta: 10,
            minMag: 0.01, maxMag: 100
        )
        let from2 = PanelyScrollView.zoomTarget(
            currentMagnification: 2.0, scrollDelta: 10,
            minMag: 0.01, maxMag: 100
        )
        // from2 should be ≈ 2× from1 (same multiplicative factor applied)
        #expect(abs(from2 - from1 * 2) < 0.001)
    }
}
