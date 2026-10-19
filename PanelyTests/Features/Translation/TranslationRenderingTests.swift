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

    /// The room inside a balloon is empty unless something's drawn there
    /// beyond the text — a line OCR didn't read.
    @Test func inkInTheRoomBesideTheTextIsMeasured() {
        let size = 80
        func balloon(withMissedLine: Bool) -> CGImage {
            let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            // The read text: top-left area (CG's origin is bottom-left).
            context.fill(CGRect(x: 10, y: 50, width: 30, height: 20))
            if withMissedLine {
                context.fill(CGRect(x: 10, y: 15, width: 50, height: 8))
            }
            return context.makeImage()!
        }
        let text = CGRect(x: 8, y: 8, width: 34, height: 24) // top-left origin
        let room = CGRect(x: 0, y: 0, width: 80, height: 80)

        #expect(BubbleBackgroundSampler.inkShare(balloon(withMissedLine: false), in: room, excluding: text, background: .white) < 0.01)
        #expect(BubbleBackgroundSampler.inkShare(balloon(withMissedLine: true), in: room, excluding: text, background: .white) > 0.03)
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

    /// In a detected balloon the translation gets the room inside it, but
    /// still covers the original and stays off the outline.
    @Test func aBalloonsRoomWidensThePatchWithinItsOutline() {
        var narrow = bubble(rect: CGRect(x: 190, y: 100, width: 20, height: 160), glyph: 20, vertical: true)
        let balloon = CGRect(x: 100, y: 60, width: 200, height: 240)
        narrow.balloonRect = balloon
        let image = CGSize(width: 1000, height: 1000)

        let patch = TranslationOverlayLayout.patchRect(for: narrow, imageSize: image)

        #expect(patch.contains(narrow.rect))
        #expect(patch.contains(TranslationOverlayLayout.roomInside(balloon)))
        #expect(balloon.insetBy(dx: 10, dy: 10).contains(patch))
        #expect(patch.width > 100)

        // Over artwork there's no flat balloon to spread into: laid out as
        // without one.
        narrow.background = BubbleBackground(red: 0.5, green: 0.4, blue: 0.3, isUniform: false)
        var withoutBalloon = narrow
        withoutBalloon.balloonRect = nil
        #expect(TranslationOverlayLayout.patchRect(for: narrow, imageSize: image)
            == TranslationOverlayLayout.patchRect(for: withoutBalloon, imageSize: image))
    }

    /// Neighbours' patches reach into each other (a vertical original is
    /// widened for a horizontal translation); laid out together they meet
    /// midway between the texts instead, each still covering its own.
    @Test func neighbouringPatchesAreCutBackToMeetMidway() {
        var left = bubble(rect: CGRect(x: 100, y: 100, width: 30, height: 300), glyph: 30, vertical: true)
        var right = bubble(rect: CGRect(x: 160, y: 100, width: 30, height: 300), glyph: 30, vertical: true)
        left.id = 0
        right.id = 1
        let page = TranslatedPage(imageWidth: 1000, imageHeight: 1000, bubbles: [left, right])
        #expect(TranslationOverlayLayout.patchRect(for: left, imageSize: page.imageSize)
            .intersects(TranslationOverlayLayout.patchRect(for: right, imageSize: page.imageSize)))

        let patches = TranslationOverlayLayout.patches(for: page)

        let a = try? #require(patches[0]), b = try? #require(patches[1])
        #expect(a.map { $0.maxX <= 145.001 } == true)
        #expect(b.map { $0.minX >= 144.999 } == true)
        #expect(a?.contains(left.rect) == true)
        #expect(b?.contains(right.rect) == true)
    }

    @Test func stackedLinesSplitTheirPaddingAndOverlappingTextsAreLeftAlone() {
        var top = bubble(rect: CGRect(x: 100, y: 100, width: 300, height: 40), glyph: 40, vertical: false)
        var bottom = bubble(rect: CGRect(x: 100, y: 150, width: 300, height: 40), glyph: 40, vertical: false)
        top.id = 0
        bottom.id = 1
        let stacked = TranslationOverlayLayout.patches(for: TranslatedPage(imageWidth: 1000, imageHeight: 1000, bubbles: [top, bottom]))
        #expect(stacked[0]?.maxY == 145)
        #expect(stacked[1]?.minY == 145)

        bottom.rect = CGRect(x: 120, y: 120, width: 300, height: 40)
        let tangled = TranslationOverlayLayout.patches(for: TranslatedPage(imageWidth: 1000, imageHeight: 1000, bubbles: [top, bottom]))
        #expect(tangled[1] == TranslationOverlayLayout.patchRect(for: bottom, imageSize: CGSize(width: 1000, height: 1000)))
    }

    /// A headline and the subhead printed across it: their texts overlap, so
    /// they're drawn in one patch, a line each in reading order — and each
    /// still opens on its own.
    @Test func balloonsWhoseTextsOverlapAreDrawnTogether() {
        var headline = bubble(rect: CGRect(x: 100, y: 100, width: 500, height: 80), glyph: 60, vertical: false)
        headline.id = 0
        headline.translation = "젊은 여성들의 자살이 연이어 발생한다"
        var subhead = bubble(rect: CGRect(x: 520, y: 140, width: 60, height: 300), glyph: 40, vertical: true)
        subhead.id = 1
        subhead.translation = "이제 네 번째"
        var neighbour = bubble(rect: CGRect(x: 100, y: 600, width: 200, height: 60), glyph: 40, vertical: false)
        neighbour.id = 2
        neighbour.translation = "옆 말풍선"
        let page = TranslatedPage(imageWidth: 1000, imageHeight: 1000, bubbles: [subhead, headline, neighbour])

        let layout = TranslationOverlayLayout.layout(for: page)

        #expect(layout.drawn.count == 2)
        let together = layout.drawn.first { $0.bubble.translation?.contains("\n") == true }
        #expect(together?.bubble.translation == "젊은 여성들의 자살이 연이어 발생한다\n이제 네 번째")
        #expect(together.map { $0.patch.contains(headline.rect) && $0.patch.contains(subhead.rect) } == true)
        #expect(layout.patches[0] == layout.patches[1])
        // Clicks: each its own text.
        #expect(layout.hitAreas[0] != layout.hitAreas[1])
        #expect(layout.hitAreas[1]?.contains(CGPoint(x: 550, y: 400)) == true)
        #expect(layout.hitAreas[0]?.contains(CGPoint(x: 550, y: 400)) == false)
    }

    @Test func aHiddenBalloonIsNeverDrawnWithOthers() {
        var shown = bubble(rect: CGRect(x: 100, y: 100, width: 300, height: 80), glyph: 40, vertical: false)
        shown.id = 0
        var hidden = bubble(rect: CGRect(x: 150, y: 120, width: 300, height: 80), glyph: 40, vertical: false)
        hidden.id = 1
        hidden.translation = "숨김"
        hidden.edit = BubbleEditState(correctedSource: nil, translationIsReaders: false, needsRetranslation: false, isHidden: true)
        shown.translation = "보임"

        let layout = TranslationOverlayLayout.layout(for: TranslatedPage(imageWidth: 1000, imageHeight: 1000, bubbles: [shown, hidden]))

        #expect(layout.drawn.map { $0.bubble.translation } == ["보임"])
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

    /// Ordinary English words still stay whole when only a modest size
    /// reduction is needed.
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

    /// A space in CJK output mustn't turn the rest of the sentence into one
    /// unbreakable word. These areas have room for several readable lines.
    @Test(arguments: [
        "そう。 学校でも、ちょっとしたことがあれば、物を壊してしまいます。",
        "是的。 在学校里，只要遇到一点小事，就会把东西弄坏。",
        "是的。 在學校裡，只要遇到一點小事，就會把東西弄壞。",
    ])
    func cjkWithSpacesUsesTheAvailableHeight(_ translation: String) throws {
        let size = CGSize(width: 176, height: 185)
        let fitted = TranslationOverlayLayout.fittedText(
            translation, in: size, maxFontSize: 38, color: .black, outline: nil
        )
        let font = try #require(fitted.string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize > 24)
        #expect(font.pointSize <= 38)
        #expect(fitted.size.width <= size.width + 0.5)
        #expect(fitted.size.height <= size.height)
    }

    /// A long space-delimited Korean compound mustn't make all the other
    /// lines tiny just to put that compound on one line.
    @Test func overlongKoreanCompoundWrapsBeforeMakingTheBalloonTiny() throws {
        let size = CGSize(width: 325, height: 383)
        let fitted = TranslationOverlayLayout.fittedText(
            "과거 4건이 아라카와구·시나가와구·나카노구·세타가야구의 쇼핑몰·도내라는 이유만으로 장소를 좁힐 수 없어.",
            in: size, maxFontSize: 38.5, color: .black, outline: nil
        )
        let font = try #require(fitted.string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize > 34)
        #expect(font.pointSize <= 38.5)
        #expect(fitted.size.width <= size.width + 0.5)
        #expect(fitted.size.height <= size.height)
    }

    /// Relaxing word preservation is only useful when the larger text also
    /// fits vertically; a short patch still needs a small font.
    @Test func emergencyWrappingStillRespectsLimitedHeight() throws {
        let size = CGSize(width: 140, height: 40)
        let fitted = TranslationOverlayLayout.fittedText(
            "아라카와구·시나가와구·나카노구·세타가야구의 쇼핑몰에서 만났습니다.",
            in: size, maxFontSize: 40, color: .black, outline: nil
        )
        let font = try #require(fitted.string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize < 20)
        #expect(fitted.size.width <= size.width + 0.5)
        #expect(fitted.size.height <= size.height)
    }

    /// A short standalone reply already wrapped naturally before this fix;
    /// adding word preservation mustn't make those replies smaller.
    @Test func standaloneKoreanReplyKeepsItsReadableSize() throws {
        let size = CGSize(width: 100, height: 120)
        let fitted = TranslationOverlayLayout.fittedText(
            "그렇다면", in: size, maxFontSize: 40, color: .black, outline: nil
        )
        let font = try #require(fitted.string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize > 36)
        #expect(fitted.size.width <= size.width + 0.5)
        #expect(fitted.size.height <= size.height)
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
