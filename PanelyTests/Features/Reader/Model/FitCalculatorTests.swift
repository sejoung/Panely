import Testing
import Foundation
import CoreGraphics
@testable import Panely

struct FitCalculatorTests {
    @Test func fitScreenPicksMinRatioForPortraitDocument() {
        let mag = FitCalculator.magnification(
            docSize: CGSize(width: 1000, height: 1500),
            viewport: CGSize(width: 800, height: 600),
            fitMode: .fitScreen
        )
        // min(800/1000, 600/1500) = min(0.8, 0.4) = 0.4
        #expect(abs(mag - 0.4) < 0.0001)
    }

    @Test func fitScreenPicksMinRatioForLandscapeDocument() {
        let mag = FitCalculator.magnification(
            docSize: CGSize(width: 2000, height: 1000),
            viewport: CGSize(width: 800, height: 600),
            fitMode: .fitScreen
        )
        // min(800/2000, 600/1000) = min(0.4, 0.6) = 0.4
        #expect(abs(mag - 0.4) < 0.0001)
    }

    @Test func fitWidthUsesWidthRatio() {
        let mag = FitCalculator.magnification(
            docSize: CGSize(width: 1000, height: 1500),
            viewport: CGSize(width: 800, height: 600),
            fitMode: .fitWidth
        )
        #expect(abs(mag - 0.8) < 0.0001)
    }

    @Test func fitHeightUsesHeightRatio() {
        let mag = FitCalculator.magnification(
            docSize: CGSize(width: 1000, height: 1500),
            viewport: CGSize(width: 800, height: 600),
            fitMode: .fitHeight
        )
        // 600 / 1500 = 0.4
        #expect(abs(mag - 0.4) < 0.0001)
    }

    @Test func fitHeightDiffersFromFitScreenForLandscapeDocument() {
        // Wide doc: fit-screen picks the smaller (width) ratio; fit-height
        // ignores width entirely and may exceed viewport horizontally.
        let landscape = CGSize(width: 2000, height: 1000)
        let viewport = CGSize(width: 800, height: 600)

        let screen = FitCalculator.magnification(docSize: landscape, viewport: viewport, fitMode: .fitScreen)
        let height = FitCalculator.magnification(docSize: landscape, viewport: viewport, fitMode: .fitHeight)

        #expect(abs(screen - 0.4) < 0.0001) // 800/2000
        #expect(abs(height - 0.6) < 0.0001) // 600/1000
        #expect(height > screen)
    }

    @Test func zeroViewportFallsBackToIdentity() {
        let mag = FitCalculator.magnification(
            docSize: CGSize(width: 1000, height: 1500),
            viewport: .zero,
            fitMode: .fitScreen
        )
        #expect(mag == 1.0)
    }

    @Test func zeroDocumentFallsBackToIdentity() {
        let mag = FitCalculator.magnification(
            docSize: .zero,
            viewport: CGSize(width: 800, height: 600),
            fitMode: .fitScreen
        )
        #expect(mag == 1.0)
    }

    @Test func calculationIsIdempotentOnRepeatedCalls() {
        let doc = CGSize(width: 1200, height: 1800)
        let viewport = CGSize(width: 900, height: 700)

        let a = FitCalculator.magnification(docSize: doc, viewport: viewport, fitMode: .fitScreen)
        let b = FitCalculator.magnification(docSize: doc, viewport: viewport, fitMode: .fitScreen)
        #expect(a == b)
    }

    @Test func toggleBetweenModesProducesDistinctAndStableValues() {
        let doc = CGSize(width: 1000, height: 1500)
        let viewport = CGSize(width: 800, height: 600)

        let screenA = FitCalculator.magnification(docSize: doc, viewport: viewport, fitMode: .fitScreen)
        let width = FitCalculator.magnification(docSize: doc, viewport: viewport, fitMode: .fitWidth)
        let screenB = FitCalculator.magnification(docSize: doc, viewport: viewport, fitMode: .fitScreen)

        #expect(screenA != width)
        #expect(screenA == screenB)  // toggling back gives identical value
    }
}
