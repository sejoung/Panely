import Testing
import Foundation
@testable import Panely

/// Pure-function coverage for the spread grouping that drives double-page
/// pairing — navigation, the visible span, and position restore all route
/// through `SpreadCalculator`, so the off-by-one "standalone cover" math is
/// pinned down here once rather than re-derived (and re-broken) at each site.
@Suite
struct SpreadCalculatorTests {

    // MARK: - Single / vertical (step 1)

    @Test func singlePageIsOnePagePerSpread() {
        for i in 0..<5 {
            #expect(SpreadCalculator.spread(containing: i, pageCount: 5, step: 1, coverAlone: false) == i..<(i + 1))
        }
        #expect(SpreadCalculator.nextStart(from: 2, pageCount: 5, step: 1, coverAlone: false) == 3)
        #expect(SpreadCalculator.nextStart(from: 4, pageCount: 5, step: 1, coverAlone: false) == nil)
        #expect(SpreadCalculator.previousStart(from: 0, pageCount: 5, step: 1, coverAlone: false) == nil)
        #expect(SpreadCalculator.previousStart(from: 3, pageCount: 5, step: 1, coverAlone: false) == 2)
    }

    @Test func coverAloneIgnoredWhenStepIsOne() {
        // The offset only applies to multi-page spreads.
        #expect(SpreadCalculator.spread(containing: 0, pageCount: 5, step: 1, coverAlone: true) == 0..<1)
        #expect(SpreadCalculator.spread(containing: 3, pageCount: 5, step: 1, coverAlone: true) == 3..<4)
    }

    // MARK: - Double, default pairing (0,1)(2,3)

    @Test func doubleDefaultPairsFromZero() {
        #expect(SpreadCalculator.spread(containing: 0, pageCount: 6, step: 2, coverAlone: false) == 0..<2)
        #expect(SpreadCalculator.spread(containing: 1, pageCount: 6, step: 2, coverAlone: false) == 0..<2)
        #expect(SpreadCalculator.spread(containing: 2, pageCount: 6, step: 2, coverAlone: false) == 2..<4)
        #expect(SpreadCalculator.spread(containing: 3, pageCount: 6, step: 2, coverAlone: false) == 2..<4)

        #expect(SpreadCalculator.nextStart(from: 0, pageCount: 6, step: 2, coverAlone: false) == 2)
        #expect(SpreadCalculator.previousStart(from: 2, pageCount: 6, step: 2, coverAlone: false) == 0)
        #expect(SpreadCalculator.previousStart(from: 0, pageCount: 6, step: 2, coverAlone: false) == nil)
    }

    // MARK: - Double, standalone cover  0 | (1,2)(3,4)

    @Test func coverAloneShiftsPairingByOne() {
        #expect(SpreadCalculator.spread(containing: 0, pageCount: 6, step: 2, coverAlone: true) == 0..<1)
        #expect(SpreadCalculator.spread(containing: 1, pageCount: 6, step: 2, coverAlone: true) == 1..<3)
        #expect(SpreadCalculator.spread(containing: 2, pageCount: 6, step: 2, coverAlone: true) == 1..<3)
        #expect(SpreadCalculator.spread(containing: 3, pageCount: 6, step: 2, coverAlone: true) == 3..<5)
        #expect(SpreadCalculator.spread(containing: 4, pageCount: 6, step: 2, coverAlone: true) == 3..<5)
        #expect(SpreadCalculator.spread(containing: 5, pageCount: 6, step: 2, coverAlone: true) == 5..<6)
    }

    @Test func coverAloneNavigationWalksWholeBook() {
        // Forward from the cover through the last (singleton) page of a 6-page
        // book: 0 → 1 → 3 → 5 → end.
        #expect(SpreadCalculator.nextStart(from: 0, pageCount: 6, step: 2, coverAlone: true) == 1)
        #expect(SpreadCalculator.nextStart(from: 1, pageCount: 6, step: 2, coverAlone: true) == 3)
        #expect(SpreadCalculator.nextStart(from: 3, pageCount: 6, step: 2, coverAlone: true) == 5)
        #expect(SpreadCalculator.nextStart(from: 5, pageCount: 6, step: 2, coverAlone: true) == nil)

        // ...and back: 5 → 3 → 1 → 0 → start.
        #expect(SpreadCalculator.previousStart(from: 5, pageCount: 6, step: 2, coverAlone: true) == 3)
        #expect(SpreadCalculator.previousStart(from: 3, pageCount: 6, step: 2, coverAlone: true) == 1)
        #expect(SpreadCalculator.previousStart(from: 1, pageCount: 6, step: 2, coverAlone: true) == 0)
        #expect(SpreadCalculator.previousStart(from: 0, pageCount: 6, step: 2, coverAlone: true) == nil)
    }

    // MARK: - Odd tails and edges

    @Test func oddTailIsSingletonInBothModes() {
        // 5 pages, default: (0,1)(2,3)(4) — last page stands alone.
        #expect(SpreadCalculator.spread(containing: 4, pageCount: 5, step: 2, coverAlone: false) == 4..<5)
        #expect(SpreadCalculator.nextStart(from: 4, pageCount: 5, step: 2, coverAlone: false) == nil)

        // 5 pages, cover-alone: 0 | (1,2)(3,4) — tail pairs cleanly.
        #expect(SpreadCalculator.spread(containing: 3, pageCount: 5, step: 2, coverAlone: true) == 3..<5)
        #expect(SpreadCalculator.nextStart(from: 3, pageCount: 5, step: 2, coverAlone: true) == nil)
    }

    @Test func outOfRangeIndexClampsToFinalSpread() {
        #expect(SpreadCalculator.spread(containing: 99, pageCount: 6, step: 2, coverAlone: false) == 4..<6)
        #expect(SpreadCalculator.spread(containing: 99, pageCount: 6, step: 2, coverAlone: true) == 5..<6)
        #expect(SpreadCalculator.spread(containing: -3, pageCount: 6, step: 2, coverAlone: true) == 0..<1)
    }

    @Test func emptySourceYieldsEmptyRange() {
        #expect(SpreadCalculator.spread(containing: 0, pageCount: 0, step: 2, coverAlone: true).isEmpty)
        #expect(SpreadCalculator.nextStart(from: 0, pageCount: 0, step: 2, coverAlone: true) == nil)
        #expect(SpreadCalculator.previousStart(from: 0, pageCount: 0, step: 2, coverAlone: true) == nil)
    }

    @Test func singlePageBookHasNoNextOrPrevious() {
        #expect(SpreadCalculator.spread(containing: 0, pageCount: 1, step: 2, coverAlone: false) == 0..<1)
        #expect(SpreadCalculator.spread(containing: 0, pageCount: 1, step: 2, coverAlone: true) == 0..<1)
        #expect(SpreadCalculator.nextStart(from: 0, pageCount: 1, step: 2, coverAlone: true) == nil)
        #expect(SpreadCalculator.previousStart(from: 0, pageCount: 1, step: 2, coverAlone: true) == nil)
    }
}
