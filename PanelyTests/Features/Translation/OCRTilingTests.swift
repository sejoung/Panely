import CoreGraphics
import Testing
@testable import Panely

struct OCRTilingTests {
    @Test func ordinaryPagesAreNotTiled() {
        // A tall manga page (A-series aspect) still goes through whole.
        #expect(OCRTiling.tiles(width: 2481, height: 3503) == [.init(top: 0, height: 3503)])
        #expect(OCRTiling.needsTiling(width: 1600, height: 3000) == false)
    }

    @Test func webtoonStripsAreTiledWithOverlapCoveringTheWholeHeight() {
        let tiles = OCRTiling.tiles(width: 1600, height: 21175)
        #expect(tiles.count > 1)
        #expect(tiles.first?.top == 0)
        #expect(tiles.last.map { $0.top + $0.height } == 21175)
        for (upper, lower) in zip(tiles, tiles.dropFirst()) {
            // Each band starts before the previous one ends — no gaps.
            #expect(lower.top < upper.top + upper.height)
            // The overlap is taller than a balloon (≥ 1000 px here).
            #expect(upper.top + upper.height - lower.top >= 1000)
        }
    }

    @Test func singleBandWhenShorterThanATile() {
        #expect(OCRTiling.tiles(forHeight: 1000, tileHeight: 2400, overlap: 1000) == [.init(top: 0, height: 1000)])
        #expect(OCRTiling.tiles(forHeight: 0, tileHeight: 2400, overlap: 1000).isEmpty)
    }

    @Test func regionsTouchingASeamAreNotWhole() {
        let middle = (isFirst: false, isLast: false)
        #expect(OCRTiling.isWhole(CGRect(x: 0, y: 100, width: 50, height: 50), bandHeight: 2400, isFirst: middle.isFirst, isLast: middle.isLast))
        #expect(!OCRTiling.isWhole(CGRect(x: 0, y: 0, width: 50, height: 50), bandHeight: 2400, isFirst: false, isLast: false))
        #expect(!OCRTiling.isWhole(CGRect(x: 0, y: 2360, width: 50, height: 40), bandHeight: 2400, isFirst: false, isLast: false))
        // The page's own top and bottom edges aren't seams.
        #expect(OCRTiling.isWhole(CGRect(x: 0, y: 0, width: 50, height: 50), bandHeight: 2400, isFirst: true, isLast: false))
        #expect(OCRTiling.isWhole(CGRect(x: 0, y: 2360, width: 50, height: 40), bandHeight: 2400, isFirst: false, isLast: true))
    }

    @Test func deduplicateKeepsTheLongerOfOverlappingRegions() {
        let partial = TextRegion(text: "誰彼構わず相", rect: CGRect(x: 880, y: 15214, width: 80, height: 300), isVertical: true, glyphSize: 70)
        let whole = TextRegion(text: "誰彼構わず相手しろって", rect: CGRect(x: 880, y: 15214, width: 80, height: 700), isVertical: true, glyphSize: 70)
        let other = TextRegion(text: "要するに！", rect: CGRect(x: 1020, y: 15219, width: 80, height: 300), isVertical: true, glyphSize: 70)

        let result = OCRTiling.deduplicate([partial, other, whole])

        #expect(result.map(\.text).sorted() == ["要するに！", "誰彼構わず相手しろって"].sorted())
    }
}
