import AppKit
import CoreGraphics
import Testing
@testable import Panely

struct BubbleBackgroundSamplerTests {
    /// A `size`² image filled with `background`, with a `textShare` fraction of
    /// its rows painted `ink` (stand-in for glyphs). Kept under the sampler's
    /// 96 px working size so no downscale blends ink into the background.
    private func makeImage(size: Int = 80, background: CGColor, ink: CGColor, textShare: Double) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(ink)
        let rows = Int(Double(size) * textShare)
        for row in stride(from: 0, to: size, by: max(1, size / max(1, rows))) where row < size {
            context.fill(CGRect(x: 0, y: row, width: size, height: 1))
        }
        return context.makeImage()!
    }

    @Test func whiteBalloonWithBlackTextSamplesWhiteAndUniform() {
        let image = makeImage(background: CGColor(red: 1, green: 1, blue: 1, alpha: 1), ink: CGColor(red: 0, green: 0, blue: 0, alpha: 1), textShare: 0.25)

        let sample = BubbleBackgroundSampler.sample(image, in: CGRect(x: 0, y: 0, width: 80, height: 80))

        #expect(sample.red > 0.95 && sample.green > 0.95 && sample.blue > 0.95)
        #expect(sample.isUniform)
        #expect(!sample.isDark)
    }

    @Test func darkBackgroundIsDetectedAsDark() {
        let image = makeImage(background: CGColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1), ink: CGColor(red: 0.9, green: 0.8, blue: 1, alpha: 1), textShare: 0.2)

        let sample = BubbleBackgroundSampler.sample(image, in: CGRect(x: 10, y: 10, width: 60, height: 60))

        #expect(sample.isDark)
        #expect(sample.isUniform)
    }

    @Test func noisyArtworkIsNotUniform() {
        let size = 120
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Deterministic multi-tone "artwork": 8 distinct bands of colour.
        for band in 0..<8 {
            let level = Double(band) / 7
            context.setFillColor(CGColor(red: level, green: 1 - level, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: band * size / 8, y: 0, width: size / 8, height: size))
        }

        let sample = BubbleBackgroundSampler.sample(context.makeImage()!, in: CGRect(x: 0, y: 0, width: size, height: size))

        #expect(!sample.isUniform)
    }

    @Test func rectOutsideTheImageFallsBackToWhite() {
        let image = makeImage(background: CGColor(red: 0, green: 0, blue: 0, alpha: 1), ink: CGColor(red: 0, green: 0, blue: 0, alpha: 1), textShare: 0)
        #expect(BubbleBackgroundSampler.sample(image, in: CGRect(x: 500, y: 500, width: 10, height: 10)) == .white)
    }
}

struct TranslationOverlayLayoutTests {
    private func bubble(rect: CGRect, glyph: Double, vertical: Bool) -> TranslatedBubble {
        TranslatedBubble(id: 0, rect: rect, glyphSize: glyph, isVertical: vertical, source: "", translation: "", background: .white)
    }

    @Test func horizontalPatchIsTheTextPlusPadding() {
        let patch = TranslationOverlayLayout.patchRect(
            for: bubble(rect: CGRect(x: 100, y: 100, width: 400, height: 80), glyph: 40, vertical: false),
            imageSize: CGSize(width: 1000, height: 1000)
        )
        #expect(patch == CGRect(x: 88, y: 88, width: 424, height: 104))
    }

    @Test func narrowVerticalPatchWidensAboutItsCentre() {
        let source = CGRect(x: 500, y: 100, width: 70, height: 600)
        let patch = TranslationOverlayLayout.patchRect(
            for: bubble(rect: source, glyph: 70, vertical: true),
            imageSize: CGSize(width: 1600, height: 2000)
        )
        #expect(patch.width > source.width * 3)
        #expect(abs(patch.midX - source.midX) < 0.001)
        #expect(patch.minY < source.minY && patch.maxY > source.maxY)
    }

    @Test func patchStaysOnThePage() {
        let patch = TranslationOverlayLayout.patchRect(
            for: bubble(rect: CGRect(x: 0, y: 0, width: 60, height: 900), glyph: 60, vertical: true),
            imageSize: CGSize(width: 300, height: 1000)
        )
        #expect(CGRect(x: 0, y: 0, width: 300, height: 1000).contains(patch))
    }

    @MainActor
    @Test func fittedTextFitsAndRespectsTheCap() {
        let size = CGSize(width: 200, height: 120)
        let fitted = TranslationOverlayLayout.fittedText(
            "무슨 일이 있어도 이 전쟁을 멈추지 않으면…",
            in: size,
            maxFontSize: 40,
            color: .black,
            outline: nil
        )
        #expect(fitted.size.height <= size.height)
        let font = fitted.string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect((font?.pointSize ?? 0) <= 40)
        #expect((font?.pointSize ?? 0) > 10)
        #expect(fitted.outline == nil)
    }

    /// A word is never broken across lines to fit a bigger size: the font
    /// shrinks until the longest word fits a line.
    @Test func fittedTextKeepsWordsWhole() {
        let size = CGSize(width: 140, height: 160)
        let fitted = TranslationOverlayLayout.fittedText(
            "I feel like I was dreaming.",
            in: size,
            maxFontSize: 40,
            color: .black,
            outline: nil
        )
        let font = fitted.string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 99)
        let longest = ("dreaming." as NSString).size(withAttributes: [.font: font]).width
        #expect(longest <= size.width + 0.5)
    }

    /// Stroking the filled text traces the system font's overlapping inner
    /// contours as stray lines; the outline is its own stroke-only pass,
    /// drawn under a plain fill.
    @MainActor
    @Test func outlineIsASeparateStrokeOnlyPass() throws {
        let fitted = TranslationOverlayLayout.fittedText(
            "After the emperor's death",
            in: CGSize(width: 200, height: 120),
            maxFontSize: 40,
            color: .black,
            outline: .white
        )
        #expect(fitted.string.attribute(.strokeWidth, at: 0, effectiveRange: nil) == nil)
        let outline = try #require(fitted.outline)
        #expect(outline.string == fitted.string.string)
        let width = try #require(outline.attribute(.strokeWidth, at: 0, effectiveRange: nil) as? Double)
        #expect(width > 0) // positive = stroke only, no fill
        #expect(outline.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            == fitted.string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    }
}
