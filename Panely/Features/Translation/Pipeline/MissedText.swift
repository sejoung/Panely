import CoreGraphics
import Foundation

/// A second look at text OCR passed over.
///
/// Vision reads a whole page at its own working size, and small or stylized
/// lines can come back empty even though the detector found a text box
/// there. Read on their own, enlarged, many of them come through (on a
/// webtoon: "こんな身—", "はあ…" — missed on the page, read in the box). Only
/// boxes the detector is fairly sure of are tried; what comes back still goes
/// through the language and sound-effect filters like any other text.
nonisolated enum MissedText {
    /// Detector confidence below which a box isn't worth a second look (most
    /// of those are artwork). Measured on a webtoon: lines recovered from boxes
    /// at 0.87–0.88, a pattern misread as text at 0.55.
    static let minimumScore: Float = 0.6
    /// A box is read enlarged to about this many pixels on its long side.
    static let targetSide: CGFloat = 640
    static let maxScale: CGFloat = 4

    /// Text boxes with no OCR text in them, once each (a box can be both
    /// "text in balloon" and "free text").
    static func boxesToReread(_ detections: [DetectedRegion], regions: [TextRegion]) -> [DetectedRegion] {
        var boxes: [DetectedRegion] = []
        for detection in detections.sorted(by: { $0.score > $1.score })
        where detection.kind != .balloon && detection.score >= minimumScore {
            let read = regions.contains {
                OCRTiling.overlapFraction($0.rect, detection.rect) > 0.3
            }
            let seen = boxes.contains { OCRTiling.overlapFraction($0.rect, detection.rect) > 0.5 }
            if !read && !seen { boxes.append(detection) }
        }
        return boxes
    }

    /// The area cut out for a box: a margin around it (the detector's box
    /// can be tight), within the image.
    static func cropRect(for box: CGRect, in imageSize: CGSize) -> CGRect {
        let margin = max(8, min(box.width, box.height) * 0.15)
        return box.insetBy(dx: -margin, dy: -margin).integral
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// How much the cut-out is enlarged before reading.
    static func scale(for crop: CGRect) -> CGFloat {
        min(maxScale, max(1, targetSide / max(crop.width, crop.height)))
    }

    /// A pattern read as text — "メーメーメーメーメー": a few characters over
    /// and over. Real lines aren't that repetitive.
    static func isNoise(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        guard letters.count >= 6 else { return false }
        return Double(Set(letters).count) / Double(letters.count) < 0.35
    }

    /// A region read in the enlarged cut-out, back in the image's pixels.
    static func mapBack(_ region: TextRegion, crop: CGRect, scale: CGFloat) -> TextRegion {
        var mapped = region
        mapped.rect = CGRect(
            x: crop.minX + region.rect.minX / scale,
            y: crop.minY + region.rect.minY / scale,
            width: region.rect.width / scale,
            height: region.rect.height / scale
        )
        mapped.glyphSize = region.glyphSize / scale
        return mapped
    }
}

/// What's in an area the reader marked out in edit mode: the text, read
/// enlarged as a second look does, and how it looks.
nonisolated struct MarkedArea: Sendable, Equatable {
    /// Empty when nothing readable was there.
    var text: String
    var glyphSize: Double
    var isVertical: Bool
    var background: BubbleBackground

    /// Read `area` (page pixels) of `image`.
    @available(macOS 26.0, *)
    static func read(_ area: CGRect, in image: CGImage, language: TranslationLanguage) async -> MarkedArea {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = area.integral.intersection(bounds)
        let background = BubbleBackgroundSampler.sample(image, in: crop)
        // Without text, a balloon of about two lines' height.
        let fallback = MarkedArea(text: "", glyphSize: Double(max(12, min(crop.width, crop.height) / 4)), isVertical: language.isWrittenVertically && crop.height > crop.width * 1.5, background: background)
        guard !crop.isNull, crop.width >= 4, crop.height >= 4 else { return fallback }

        let scale = MissedText.scale(for: crop)
        guard let cut = image.cropping(to: crop),
              let context = CGContext(
                data: nil, width: Int(crop.width * scale), height: Int(crop.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return fallback }
        context.interpolationQuality = .high
        context.draw(cut, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let enlarged = context.makeImage(),
              let regions = try? await PageTextRecognizer(language: language).recognize(enlarged)
        else { return fallback }

        // All of it is one balloon: the reader said so.
        let drafts = BubbleGrouper.group(regions.map { MissedText.mapBack($0, crop: crop, scale: scale) }, language: language)
        guard !drafts.isEmpty else { return fallback }
        return MarkedArea(
            text: drafts.map(\.source).joined(separator: language.lineJoiner),
            glyphSize: Double(drafts.map(\.glyphSize).min() ?? CGFloat(fallback.glyphSize)),
            isVertical: drafts.filter(\.isVertical).count * 2 > drafts.count,
            background: background
        )
    }
}
