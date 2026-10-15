import CoreGraphics
import Foundation
import Testing
@testable import Panely

/// The detector's output decoding, chunking of tall strips, and grouping OCR
/// text by detected balloons.
struct BalloonDetectionTests {
    @Test func outputsDecodeToPixelRectsMostConfidentFirst() {
        // Two queries × three classes; query 0 is a balloon, query 1 free text.
        let scores: [Float] = [0.9, 0.1, 0.0, 0.0, 0.2, 0.7]
        let boxes: [Float] = [0.5, 0.25, 0.5, 0.5, 0.1, 0.9, 0.1, 0.1]
        let found = BalloonDetection.decode(scores: scores, boxes: boxes, imageSize: CGSize(width: 200, height: 400))

        #expect(found.map(\.kind) == [.balloon, .freeText])
        #expect(found[0].rect == CGRect(x: 50, y: 0, width: 100, height: 200))
        #expect(found[1].rect.origin.x.rounded() == 10 && found[1].rect.origin.y.rounded() == 340)
    }

    @Test func pagesGoWholeAndStripsInOverlappingChunks() {
        #expect(BalloonDetection.chunks(width: 1500, height: 2109).count == 1)
        let strip = BalloonDetection.chunks(width: 720, height: 6000)
        #expect(strip.count > 3)
        #expect(strip.first?.top == 0)
        #expect(strip.last.map { $0.top + $0.height } == 6000)
        // Neighbours overlap, so a balloon cut by one seam is whole in the next chunk.
        for (a, b) in zip(strip, strip.dropFirst()) {
            #expect(b.top < a.top + a.height)
        }
    }

    @Test func aRegionSeenByTwoChunksIsKeptOnce() {
        let rect = CGRect(x: 10, y: 100, width: 50, height: 50)
        let regions = [
            DetectedRegion(kind: .balloon, rect: rect, score: 0.8),
            DetectedRegion(kind: .balloon, rect: rect.offsetBy(dx: 2, dy: 1), score: 0.9),
            DetectedRegion(kind: .textInBalloon, rect: rect, score: 0.7),
        ]
        let kept = BalloonDetection.deduplicate(regions)
        #expect(kept.count == 2)
        #expect(kept.first { $0.kind == .balloon }?.score == 0.9)
    }
}

struct BubbleGrouperDetectionTests {
    private func region(_ text: String, _ rect: CGRect, vertical: Bool = true) -> TextRegion {
        TextRegion(text: text, rect: rect, isVertical: vertical, glyphSize: 20)
    }

    private func balloon(_ rect: CGRect) -> DetectedRegion {
        DetectedRegion(kind: .balloon, rect: rect, score: 0.9)
    }

    private func text(_ rect: CGRect, free: Bool = false) -> DetectedRegion {
        DetectedRegion(kind: free ? .freeText : .textInBalloon, rect: rect, score: 0.9)
    }

    @Test func columnsOfOneBalloonJoinRightToLeftHoweverOCRSplitThem() {
        // Far enough apart that the layout rules leave them in two pieces;
        // OCR even called them horizontal.
        let right = region("ですが私は教皇として", CGRect(x: 499, y: 923, width: 82, height: 172), vertical: false)
        let left = region("範となるべき立場では…？", CGRect(x: 412, y: 923, width: 78, height: 208), vertical: false)
        let detections = [balloon(CGRect(x: 325, y: 860, width: 340, height: 320)), text(CGRect(x: 367, y: 900, width: 253, height: 262))]

        let drafts = BubbleGrouper.group([left, right], language: .japanese, detections: detections)

        #expect(drafts.map(\.source) == ["ですが私は教皇として範となるべき立場では…？"])
    }

    @Test func piecesOfOneColumnReadTopToBottom() {
        let top = region("ただ", CGRect(x: 237, y: 1094, width: 35, height: 56))
        let below = region("今", CGRect(x: 240, y: 1160, width: 37, height: 40))
        let detections = [balloon(CGRect(x: 200, y: 1080, width: 120, height: 140))]

        #expect(BubbleGrouper.group([below, top], language: .japanese, detections: detections).map(\.source) == ["ただ今"])
    }

    @Test func neighbouringBalloonsStayApart() {
        // Close enough that the layout rules would merge them.
        let a = region("やっと", CGRect(x: 300, y: 100, width: 30, height: 120))
        let b = region("目が覚めた", CGRect(x: 265, y: 110, width: 30, height: 150))
        let detections = [
            balloon(CGRect(x: 290, y: 80, width: 60, height: 160)),
            balloon(CGRect(x: 255, y: 90, width: 34, height: 190)),
        ]
        #expect(BubbleGrouper.group([a, b], language: .japanese).count == 1)

        #expect(BubbleGrouper.group([a, b], language: .japanese, detections: detections).count == 2)
    }

    @Test func anAsideInsideARoundBalloonsCornerStaysOnItsOwn() {
        let main = region("これを書いた者は実体験がないのでしょうね", CGRect(x: 120, y: 20, width: 160, height: 200))
        let aside = region("これだから机上の学者というものは…", CGRect(x: 60, y: 200, width: 70, height: 90))
        let detections = [
            balloon(CGRect(x: 50, y: 0, width: 260, height: 300)),
            text(CGRect(x: 110, y: 10, width: 180, height: 220)),
            text(CGRect(x: 55, y: 195, width: 80, height: 100), free: true),
        ]
        #expect(BubbleGrouper.group([main, aside], language: .japanese, detections: detections).count == 2)
    }

    /// Text the detector missed is kept, short or not: a title in decorative
    /// lettering, the last column of a balloon ("ですか…") — real webtoon
    /// cases a "drop it" rule lost.
    @Test func textOutsideEveryBalloonIsKept() {
        let speech = region("無理だよ", CGRect(x: 100, y: 100, width: 30, height: 100))
        let missedColumn = region("ですか…", CGRect(x: 400, y: 400, width: 30, height: 130))
        let title = region("世界一", CGRect(x: 80, y: 600, width: 296, height: 165), vertical: false)
        let detections = [balloon(CGRect(x: 80, y: 80, width: 80, height: 150))]

        let drafts = BubbleGrouper.group([speech, missedColumn, title], language: .japanese, detections: detections)

        #expect(Set(drafts.map(\.source)) == ["無理だよ", "ですか…", "世界一"])
        // Only text in a detected balloon gets its room.
        #expect(drafts.first { $0.source == "無理だよ" }?.balloonRect != nil)
        #expect(drafts.first { $0.source == "ですか…" }?.balloonRect == nil)
    }

    @Test func nothingDetectedFallsBackToTheLayoutRules() {
        let a = region("やっと", CGRect(x: 300, y: 100, width: 30, height: 120))
        let b = region("目が覚めた", CGRect(x: 265, y: 110, width: 30, height: 150))
        #expect(BubbleGrouper.group([a, b], language: .japanese, detections: []) == BubbleGrouper.group([a, b], language: .japanese))
    }
}

/// The bundled model loads and runs. Kept small: one blank page.
struct BalloonDetectorModelTests {
    @Test func bundledModelRuns() async throws {
        let context = try #require(CGContext(
            data: nil, width: 600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
        let blank = try #require(context.makeImage())

        let found = await BalloonDetector.shared.detect(blank)

        // Loaded and ran (nil would mean it couldn't); nothing on a blank page.
        #expect(found != nil)
        #expect(found?.filter { $0.score > 0.6 }.isEmpty == true)
    }
}
