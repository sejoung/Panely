import CoreGraphics
import Testing
@testable import Panely

/// Picking the text boxes OCR left empty, and placing what a second look
/// reads back on the page.
struct MissedTextTests {
    private func region(_ rect: CGRect) -> TextRegion {
        TextRegion(text: "こんな身", rect: rect, isVertical: true, glyphSize: 20)
    }

    @Test func onlyConfidentTextBoxesWithNothingReadInThemOnce() {
        let read = CGRect(x: 0, y: 0, width: 50, height: 100)
        let empty = CGRect(x: 200, y: 0, width: 50, height: 100)
        let detections = [
            DetectedRegion(kind: .textInBalloon, rect: read, score: 0.9),
            DetectedRegion(kind: .textInBalloon, rect: empty, score: 0.87),
            // The same box as free text: tried once.
            DetectedRegion(kind: .freeText, rect: empty, score: 0.62),
            // Balloons themselves aren't text; unsure boxes are mostly artwork.
            DetectedRegion(kind: .balloon, rect: CGRect(x: 400, y: 0, width: 80, height: 120), score: 0.95),
            DetectedRegion(kind: .freeText, rect: CGRect(x: 600, y: 0, width: 50, height: 50), score: 0.55),
        ]

        let boxes = MissedText.boxesToReread(detections, regions: [region(read)])

        #expect(boxes.map(\.rect) == [empty])
    }

    @Test func whatsReadEnlargedLandsWhereItIsOnThePage() {
        let crop = MissedText.cropRect(for: CGRect(x: 100, y: 200, width: 40, height: 80), in: CGSize(width: 720, height: 2304))
        let scale = MissedText.scale(for: crop)
        #expect(scale > 1 && scale <= MissedText.maxScale)
        #expect(crop.contains(CGRect(x: 100, y: 200, width: 40, height: 80)))

        let inCrop = TextRegion(text: "はあ", rect: CGRect(x: 10 * scale, y: 20 * scale, width: 30 * scale, height: 60 * scale), isVertical: true, glyphSize: 18 * scale)
        let mapped = MissedText.mapBack(inCrop, crop: crop, scale: scale)

        #expect(abs(mapped.rect.minX - (crop.minX + 10)) < 0.001)
        #expect(abs(mapped.rect.height - 60) < 0.001)
        #expect(abs(mapped.glyphSize - 18) < 0.001)
    }

    @Test func aPatternReadAsTextIsNoise() {
        #expect(MissedText.isNoise("1メーターメーメーメーメーメーメーメ"))
        #expect(!MissedText.isNoise("こんな身—"))
        #expect(!MissedText.isNoise("はあ…"))
        #expect(!MissedText.isNoise("あの方のお導きに誤りなどあるはずがございません"))
    }
}
