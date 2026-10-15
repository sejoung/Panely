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

    /// How a page's translations are laid out: one patch per balloon, or
    /// per group of balloons drawn together, and where each balloon answers
    /// clicks.
    struct PageLayout {
        /// Where each balloon's translation is drawn (page pixels), by id.
        /// Balloons drawn together share their group's patch.
        var patches: [Int: CGRect] = [:]
        /// Where each balloon takes clicks: its own patch, or — drawn in a
        /// group — the area of its own text, so each can still be opened.
        var hitAreas: [Int: CGRect] = [:]
        /// What to paint: each balloon with a translation, or one stand-in per
        /// group carrying its balloons' translations a line each.
        var drawn: [(bubble: TranslatedBubble, patch: CGRect)] = []

        /// Everything drawn, in page pixels: the page itself plus any patch
        /// reaching past it (see `contentRect(for:)`).
        func contentRect(imageSize: CGSize) -> CGRect {
            patches.values.reduce(CGRect(origin: .zero, size: imageSize)) { $0.union($1) }
        }
    }

    /// Lay out a page's translations so none covers another.
    ///
    /// Balloons whose texts overlap — a newspaper headline and the subhead
    /// printed across it — can't be given separate patches without one
    /// painting over the other, so they're drawn together: one patch over
    /// both, their translations (made separately — they're separate
    /// sentences) a line each, in reading order.
    ///
    /// Every other patch reaches past its text (padding, the room a vertical
    /// original is widened by, the room inside a balloon); two reaches can
    /// meet, and the later one would paint over the other (67 overlapping
    /// pairs in one reader's cache, 7 of them texts overlapping). Where two
    /// patches overlap, their reaches are cut back to the line midway between
    /// their texts — never into the text itself, so each still hides its
    /// original — and the translation is fitted to what's left.
    static func layout(for page: TranslatedPage) -> PageLayout {
        let bubbles = page.bubbles
        let own = bubbles.map { patchRect(for: $0, imageSize: page.imageSize) }
        let cores = bubbles.map { core(of: $0, imageSize: page.imageSize) }

        // Balloons drawn together: shown translations whose texts overlap.
        let shown = bubbles.indices.filter { bubbles[$0].isShownTranslation }
        var parent = Array(bubbles.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in shown {
            for j in shown where j > i && cores[i].intersects(cores[j]) {
                parent[root(j)] = root(i)
            }
        }
        // Units laid out against each other: a group, or a balloon alone.
        var units: [[Int]] = []
        var unitOf: [Int: Int] = [:]
        for i in bubbles.indices {
            if let unit = unitOf[root(i)] {
                units[unit].append(i)
            } else {
                unitOf[root(i)] = units.count
                units.append([i])
            }
        }
        var patches = units.map { $0.dropFirst().reduce(own[$0[0]]) { $0.union(own[$1]) } }
        let unitCores = units.map { $0.dropFirst().reduce(cores[$0[0]]) { $0.union(cores[$1]) } }

        for i in units.indices {
            for j in units.indices where j > i && patches[i].intersects(patches[j]) && !unitCores[i].intersects(unitCores[j]) {
                let a = unitCores[i], b = unitCores[j]
                let gapX = max(b.minX - a.maxX, a.minX - b.maxX)
                let gapY = max(b.minY - a.maxY, a.minY - b.maxY)
                if gapX >= gapY {
                    let (left, right) = a.midX < b.midX ? (i, j) : (j, i)
                    let boundary = (unitCores[left].maxX + unitCores[right].minX) / 2
                    patches[left] = trimmed(patches[left], maxX: max(unitCores[left].maxX, boundary))
                    patches[right] = trimmed(patches[right], minX: min(unitCores[right].minX, boundary))
                } else {
                    let (top, bottom) = a.midY < b.midY ? (i, j) : (j, i)
                    let boundary = (unitCores[top].maxY + unitCores[bottom].minY) / 2
                    patches[top] = trimmed(patches[top], maxY: max(unitCores[top].maxY, boundary))
                    patches[bottom] = trimmed(patches[bottom], minY: min(unitCores[bottom].minY, boundary))
                }
            }
        }

        var layout = PageLayout()
        for (unit, members) in units.enumerated() {
            for index in members {
                let id = bubbles[index].id
                layout.patches[id] = layout.patches[id] ?? patches[unit]
                let glyph = CGFloat(bubbles[index].glyphSize)
                layout.hitAreas[id] = layout.hitAreas[id]
                    ?? (members.count > 1 ? bubbles[index].rect.insetBy(dx: -glyph * 0.3, dy: -glyph * 0.3) : patches[unit])
            }
            let painted = members.filter { bubbles[$0].isShownTranslation }
            guard let first = painted.first else { continue }
            if painted.count == 1 {
                layout.drawn.append((bubbles[first], patches[unit]))
                continue
            }
            // In the order the page reads (the analysis numbers balloons that way).
            let ordered = painted.sorted { bubbles[$0].id < bubbles[$1].id }
            var together = bubbles[ordered[0]]
            together.translation = ordered.compactMap { bubbles[$0].translation }.joined(separator: "\n")
            together.glyphSize = ordered.map { bubbles[$0].glyphSize }.min() ?? together.glyphSize
            // The tone of the largest; flat only if all of them are.
            let largest = ordered.max { area(bubbles[$0].rect) < area(bubbles[$1].rect) } ?? ordered[0]
            together.background = bubbles[largest].background
            together.background.isUniform = ordered.allSatisfy { bubbles[$0].background.isUniform }
            layout.drawn.append((together, patches[unit]))
        }
        return layout
    }

    /// Every balloon's patch on a page, by balloon id (see `layout(for:)`).
    static func patches(for page: TranslatedPage) -> [Int: CGRect] {
        layout(for: page).patches
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    /// What a patch must cover whatever its neighbours: the text itself.
    /// Between two texts close together, each keeps the padding on its side
    /// of the midline.
    private static func core(of bubble: TranslatedBubble, imageSize: CGSize) -> CGRect {
        let clipped = bubble.rect.intersection(CGRect(x: 0, y: bubble.rect.minY, width: imageSize.width, height: bubble.rect.height))
        return clipped.isNull ? bubble.rect : clipped
    }

    private static func trimmed(
        _ rect: CGRect,
        minX: CGFloat? = nil, maxX: CGFloat? = nil, minY: CGFloat? = nil, maxY: CGFloat? = nil
    ) -> CGRect {
        let left = max(rect.minX, minX ?? rect.minX)
        let right = min(rect.maxX, maxX ?? rect.maxX)
        let top = max(rect.minY, minY ?? rect.minY)
        let bottom = min(rect.maxY, maxY ?? rect.maxY)
        return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    /// Everything a page's overlay draws, in page pixels: the page itself plus
    /// any balloon reaching past it.
    static func contentRect(for page: TranslatedPage) -> CGRect {
        layout(for: page).contentRect(imageSize: page.imageSize)
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        // Korean breaks between words (eojeol), not mid-word syllables.
        paragraph.lineBreakStrategy = .hangulWordPriority
        func make(_ fontSize: CGFloat) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
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
            // The word check first: it's the cheap one, and a size it rules
            // out needn't be laid out at all.
            guard wordsFit(mid) else {
                high = mid
                continue
            }
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

extension TranslatedBubble {
    /// Has a translation on screen: translated, not left empty by a failed
    /// unit, not hidden.
    nonisolated var isShownTranslation: Bool {
        guard edit?.isHidden != true, let translation else { return false }
        return !translation.isEmpty
    }
}
