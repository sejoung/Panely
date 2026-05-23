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

    @Test func commandScrollZoomCenterUsesDocumentCoordinates() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        let scrollView = PanelyScrollView(frame: NSRect(x: 20, y: 30, width: 300, height: 240))
        let document = NSView(frame: NSRect(x: 40, y: 60, width: 900, height: 720))
        scrollView.documentView = document
        window.contentView?.addSubview(scrollView)

        let localInScrollView = NSPoint(x: 120, y: 90)
        let windowPoint = scrollView.convert(localInScrollView, to: nil)
        let center = PanelyScrollView.zoomCenter(
            eventLocationInWindow: windowPoint,
            documentView: document
        )

        #expect(center == document.convert(windowPoint, from: nil))
        #expect(center != scrollView.convert(windowPoint, from: nil))
    }
}
