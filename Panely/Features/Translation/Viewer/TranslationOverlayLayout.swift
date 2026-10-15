import AppKit
import Foundation

/// Geometry and text fitting for translation patches — kept apart from the
/// view so it's testable without a window.
nonisolated enum TranslationOverlayLayout {
    /// Area a balloon's translation covers, in page pixels.
    ///
    /// The source text plus padding (glyph outlines and glow spill past the OCR
    /// box, and the patch has to hide them). Vertical source text is tall and
    /// narrow, which would leave a horizontal translation one or two
    /// characters per line, so its patch is widened about its centre.
    ///
    /// Kept within the page's width, and within its height unless the balloon
    /// itself runs past the page — a strip balloon crossing into the next
    /// slice keeps its full extent.
    static func patchRect(for bubble: TranslatedBubble, imageSize: CGSize) -> CGRect {
        let glyph = CGFloat(bubble.glyphSize)
        var rect = bubble.rect.insetBy(dx: -glyph * 0.3, dy: -glyph * 0.3)
        if bubble.isVertical {
            let minWidth = min(rect.height * 0.9, glyph * 9)
            if rect.width < minWidth {
                rect = rect.insetBy(dx: -(minWidth - rect.width) / 2, dy: 0)
            }
        }
        let bounds = CGRect(origin: .zero, size: imageSize).union(bubble.rect)
        let clipped = rect.intersection(CGRect(x: 0, y: bounds.minY, width: imageSize.width, height: bounds.height))
        return clipped.isNull ? .zero : clipped
    }

    /// Everything a page's overlay draws, in page pixels: the page itself plus
    /// any balloon reaching past it.
    static func contentRect(for page: TranslatedPage) -> CGRect {
        page.bubbles.reduce(CGRect(origin: .zero, size: page.imageSize)) {
            $0.union(patchRect(for: $1, imageSize: page.imageSize))
        }
    }

    /// The translation at the largest font size that fits `size`, capped at
    /// `maxFontSize` (the source glyph size — a translation shouldn't shout
    /// louder than the original). Returns the string, its laid-out size and,
    /// when `outline` is given, the same text as an outline to draw *under*
    /// it.
    ///
    /// The outline is a separate pass on purpose: the system font's glyphs are
    /// built from overlapping contours, and stroking the filled text (a
    /// negative stroke width) traces those inner overlaps too — stray light
    /// lines through "e", "A", "t". Filled on top, the inner strokes vanish
    /// and only the halo around each letter shows.
    @MainActor
    static func fittedText(
        _ text: String,
        in size: CGSize,
        maxFontSize: CGFloat,
        minFontSize: CGFloat = 6,
        color: NSColor,
        outline: NSColor?
    ) -> (string: NSAttributedString, outline: NSAttributedString?, size: CGSize) {
        func make(_ fontSize: CGFloat) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            // Korean breaks between words (eojeol), not mid-word syllables.
            paragraph.lineBreakStrategy = .hangulWordPriority
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])
        }
        func measure(_ string: NSAttributedString) -> CGSize {
            string.boundingRect(
                with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).size
        }

        var low = minFontSize
        var high = max(minFontSize, maxFontSize)
        var best = make(low)
        var bestSize = measure(best)
        while high - low > 0.5 {
            let mid = (low + high) / 2
            let candidate = make(mid)
            let candidateSize = measure(candidate)
            if candidateSize.height <= size.height && candidateSize.width <= size.width + 0.5 {
                best = candidate
                bestSize = candidateSize
                low = mid
            } else {
                high = mid
            }
        }
        // Over artwork the patch is feathered, so an outline keeps the
        // letters legible against whatever shows through. Stroke only (a
        // positive width, centred on the contour): half of it shows outside
        // the letters once the fill is drawn over it.
        let outlined = outline.map { outline in
            let string = NSMutableAttributedString(attributedString: best)
            let range = NSRange(location: 0, length: string.length)
            string.addAttributes([
                .foregroundColor: NSColor.clear,
                .strokeColor: outline,
                .strokeWidth: 4.0,
            ], range: range)
            return NSAttributedString(attributedString: string)
        }
        return (best, outlined, bestSize)
    }
}

extension TranslatedPage {
    nonisolated var imageSize: CGSize { CGSize(width: imageWidth, height: imageHeight) }
}
