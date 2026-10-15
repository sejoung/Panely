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
    /// In a detected balloon (`TranslatedBubble.balloonRect`) of one flat
    /// tone, the patch also takes the room inside the balloon — the part of
    /// its box an ellipse is sure to contain — so a translation isn't
    /// squeezed into the original's narrow column when the balloon has space
    /// around it. It never reaches the balloon's outline.
    ///
    /// Kept within the page's width, and within its height unless the balloon
    /// itself runs past the page — a strip balloon crossing into the next
    /// slice keeps its full extent.
    static func patchRect(for bubble: TranslatedBubble, imageSize: CGSize) -> CGRect {
        let glyph = CGFloat(bubble.glyphSize)
        var rect = bubble.rect.insetBy(dx: -glyph * 0.3, dy: -glyph * 0.3)
        if let balloon = bubble.balloonRect, bubble.background.isUniform {
            rect = rect.union(roomInside(balloon))
        } else if bubble.isVertical {
            let minWidth = min(rect.height * 0.9, glyph * 9)
            if rect.width < minWidth {
                rect = rect.insetBy(dx: -(minWidth - rect.width) / 2, dy: 0)
            }
        }
        let bounds = CGRect(origin: .zero, size: imageSize).union(bubble.rect)
        let clipped = rect.intersection(CGRect(x: 0, y: bounds.minY, width: imageSize.width, height: bounds.height))
        return clipped.isNull ? .zero : clipped
    }

    /// The rectangle inside a balloon's box that its outline can't cross:
    /// the largest one an ellipse holds is 71% of its box each way; a little
    /// less leaves the outline's stroke alone. Rectangular boxes and clouds
    /// have at least that much room.
    static func roomInside(_ balloon: CGRect) -> CGRect {
        let share: CGFloat = 0.66
        return balloon.insetBy(dx: balloon.width * (1 - share) / 2, dy: balloon.height * (1 - share) / 2)
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

        // Measured against the width it's wrapped to, a word too long for a
        // line is broken mid-word ("dreamin / g.") and still reports as
        // fitting — so each word must fit a line on its own. Only for text
        // that breaks at spaces: Japanese or Chinese wraps anywhere.
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func wordsFit(_ fontSize: CGFloat) -> Bool {
            guard words.count > 1 else { return true }
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            return words.allSatisfy { (($0 as NSString).size(withAttributes: [.font: font]).width) <= size.width + 0.5 }
        }

        var low = minFontSize
        var high = max(minFontSize, maxFontSize)
        var best = make(low)
        var bestSize = measure(best)
        while high - low > 0.5 {
            let mid = (low + high) / 2
            let candidate = make(mid)
            let candidateSize = measure(candidate)
            if candidateSize.height <= size.height && candidateSize.width <= size.width + 0.5 && wordsFit(mid) {
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

/// Paints one balloon's translation: the patch in the balloon's own tone
/// (feathered over artwork) and the fitted text on it. Shared by the overlay
/// on screen and the exporter, so an exported page looks the way it read.
///
/// Draws into the current `NSGraphicsContext`, which must be flipped (top-
/// left origin). Safe off the main thread — the exporter runs it in the
/// background, one page per context.
nonisolated enum TranslationPatchPainter {
    /// The text as fitted to a patch, worth keeping while neither changes.
    struct Fitted {
        let text: String
        let string: NSAttributedString
        let outline: NSAttributedString?
        let size: CGSize
    }

    /// - Parameters:
    ///   - glyph: the balloon's glyph size at the drawing scale.
    ///   - fitted: a previous fit of the same text to the same patch size.
    /// - Returns: the fit used, for the caller to cache; `nil` when the patch
    ///   is too small for text.
    @discardableResult
    static func draw(
        _ translation: String,
        background: BubbleBackground,
        glyph: CGFloat,
        in patch: CGRect,
        fitted: Fitted? = nil
    ) -> Fitted? {
        let fill = NSColor(srgbRed: background.red, green: background.green, blue: background.blue, alpha: 1)
        let path = NSBezierPath(roundedRect: patch, xRadius: max(4, glyph * 0.5), yRadius: max(4, glyph * 0.5))

        if background.isUniform {
            // A balloon or caption box: a solid patch in its own tone is invisible.
            fill.setFill()
            path.fill()
        } else {
            // Over artwork a hard box looks pasted on — feather its edge into
            // the drawing instead.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = fill
            shadow.shadowBlurRadius = max(6, glyph * 0.8)
            shadow.shadowOffset = .zero
            shadow.set()
            fill.withAlphaComponent(0.92).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let inner = patch.insetBy(dx: glyph * 0.3, dy: glyph * 0.3)
        guard inner.width > 4, inner.height > 4 else { return nil }
        let text: Fitted
        if let fitted, fitted.text == translation {
            text = fitted
        } else {
            let made = TranslationOverlayLayout.fittedText(
                translation,
                in: inner.size,
                maxFontSize: max(glyph * 0.95, 8),
                color: background.isDark ? .white : .black,
                outline: background.isUniform ? nil : (background.isDark ? .black : .white)
            )
            text = Fitted(text: translation, string: made.string, outline: made.outline, size: made.size)
        }
        let textRect = CGRect(
            x: inner.minX,
            y: inner.midY - text.size.height / 2,
            width: inner.width,
            height: text.size.height + 1
        )
        if let outline = text.outline {
            // Round joins: mitred corners spike out of "A", "M", "V".
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setLineJoin(.round)
            outline.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
        }
        text.string.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        return text
    }
}
