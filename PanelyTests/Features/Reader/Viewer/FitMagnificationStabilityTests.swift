import Testing
import Foundation
import AppKit
@testable import Panely

@MainActor
struct FitMagnificationStabilityTests {
    /// Core bug contract: viewport must be derived from a property that is
    /// invariant to the scroll view's current magnification. `contentSize`
    /// qualifies; `contentView.bounds.size` does not (it is document-space
    /// and scales inversely with magnification).
    @Test func contentSizeIsInvariantToMagnificationWhileBoundsIsNot() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        scrollView.magnification = 1.0
        scrollView.layoutSubtreeIfNeeded()
        let sizeAt1 = scrollView.contentSize
        let boundsAt1 = scrollView.contentView.bounds.size

        scrollView.magnification = 0.3
        scrollView.layoutSubtreeIfNeeded()
        let sizeAt03 = scrollView.contentSize
        let boundsAt03 = scrollView.contentView.bounds.size

        // contentSize holds the physical viewport dimensions — stable.
        #expect(abs(sizeAt1.width - sizeAt03.width) < 1.0)
        #expect(abs(sizeAt1.height - sizeAt03.height) < 1.0)

        // bounds is document-space and expands as magnification shrinks.
        #expect(boundsAt03.width > boundsAt1.width * 1.5)
    }

    /// Toggling fit modes repeatedly must produce stable magnifications.
    /// This regresses the bug where fit was computed from
    /// `contentView.bounds.size`, causing a feedback loop where each toggle
    /// produced a different magnification than the previous occurrence of
    /// that same fit mode.
    @Test func fitScreenToFitWidthBackToFitScreenIsStable() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        func applyFit(_ mode: FitMode) -> CGFloat {
            let fit = FitCalculator.magnification(
                docSize: doc.frame.size,
                viewport: scrollView.contentSize,
                fitMode: mode
            )
            scrollView.magnification = fit
            scrollView.layoutSubtreeIfNeeded()
            return fit
        }

        let firstFitScreen = applyFit(.fitScreen)
        let fitWidth = applyFit(.fitWidth)
        let secondFitScreen = applyFit(.fitScreen)
        let thirdFitScreen = applyFit(.fitScreen)
        let secondFitWidth = applyFit(.fitWidth)

        // Fit Screen values stay identical no matter how many toggles occurred
        #expect(abs(firstFitScreen - secondFitScreen) < 0.001)
        #expect(abs(firstFitScreen - thirdFitScreen) < 0.001)

        // Fit Width values stay identical as well
        #expect(abs(fitWidth - secondFitWidth) < 0.001)

        // And the two modes remain distinct
        #expect(abs(firstFitScreen - fitWidth) > 0.1)
    }

    private static func makeScrollView(size: CGSize) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 10.0
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }
}
