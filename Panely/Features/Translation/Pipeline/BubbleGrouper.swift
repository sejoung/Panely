import CoreGraphics
import Foundation

/// A balloon's worth of source text, ready to translate.
nonisolated struct BubbleDraft: Equatable, Sendable {
    var rect: CGRect
    var glyphSize: CGFloat
    var isVertical: Bool
    var source: String
}

/// Turns Vision's paragraphs into balloons.
///
/// Vision's paragraphs don't line up with balloons: vertical (tategaki) text
/// often comes back one paragraph per column or two, and a line set in a
/// different size (a name, a shout) splits from the rest of its balloon.
/// Translating those fragments separately loses the sentence, so fragments
/// that sit together the way one balloon's text does are merged:
/// - vertical columns side by side, tops roughly aligned, about a column apart;
/// - horizontal lines stacked closely with overlapping extents.
/// Merging is deliberately conservative — two balloons fused into one is worse
/// than one balloon left in two pieces.
nonisolated enum BubbleGrouper {
    static func group(_ regions: [TextRegion], language: TranslationLanguage) -> [BubbleDraft] {
        let candidates = regions.compactMap { region -> TextRegion? in
            var cleaned = region
            cleaned.text = TranslationTextNormalizer.normalize(region.text, language: language)
            guard !cleaned.text.isEmpty, language.containsOwnScript(cleaned.text) else { return nil }
            return cleaned
        }

        var parent = Array(candidates.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in candidates.indices {
            for j in candidates.indices where j > i && belongTogether(candidates[i], candidates[j]) {
                parent[root(i)] = root(j)
            }
        }

        var groups: [Int: [TextRegion]] = [:]
        for i in candidates.indices {
            groups[root(i), default: []].append(candidates[i])
        }

        return groups.values
            .map { makeDraft(from: $0, language: language) }
            .sorted { a, b in
                if abs(a.rect.minY - b.rect.minY) > 1 { return a.rect.minY < b.rect.minY }
                return a.rect.midX > b.rect.midX
            }
    }

    static func belongTogether(_ a: TextRegion, _ b: TextRegion) -> Bool {
        guard a.isVertical == b.isVertical else { return false }
        let glyph = max(min(a.glyphSize, b.glyphSize), 1)
        if a.isVertical {
            let gapX = max(a.rect.minX, b.rect.minX) - min(a.rect.maxX, b.rect.maxX)
            let overlapY = min(a.rect.maxY, b.rect.maxY) - max(a.rect.minY, b.rect.minY)
            let topsAlign = abs(a.rect.minY - b.rect.minY) < glyph * 2.5
            return gapX < glyph * 1.3
                && overlapY > 0.3 * min(a.rect.height, b.rect.height)
                && topsAlign
        } else {
            let gapY = max(a.rect.minY, b.rect.minY) - min(a.rect.maxY, b.rect.maxY)
            let overlapX = min(a.rect.maxX, b.rect.maxX) - max(a.rect.minX, b.rect.minX)
            return gapY < glyph * 0.8
                && overlapX > 0.5 * min(a.rect.width, b.rect.width)
        }
    }

    private static func makeDraft(from parts: [TextRegion], language: TranslationLanguage) -> BubbleDraft {
        let isVertical = parts[0].isVertical
        // Reading order inside the balloon: tategaki columns run right to
        // left; horizontal lines top to bottom.
        let ordered = isVertical
            ? parts.sorted { $0.rect.midX > $1.rect.midX }
            : parts.sorted { $0.rect.minY < $1.rect.minY }
        let rect = ordered.dropFirst().reduce(ordered[0].rect) { $0.union($1.rect) }
        let source = TranslationTextNormalizer.normalize(
            ordered.map(\.text).joined(separator: language.lineJoiner),
            language: language
        )
        return BubbleDraft(
            rect: rect,
            glyphSize: ordered.map(\.glyphSize).min() ?? 0,
            isVertical: isVertical,
            source: source
        )
    }
}

/// Cleans OCR text before translation.
nonisolated enum TranslationTextNormalizer {
    static func normalize(_ text: String, language: TranslationLanguage) -> String {
        var result = text.replacingOccurrences(of: "\n", with: language.lineJoiner)
        // OCR renders one ellipsis many ways (・・, ••, ⋯, ..., …。); the
        // translator handles a single "…" far better than any of those.
        result = result.replacing(try! Regex("[・•⋯…‥.。]{2,}"), with: "…")
        result = result.replacing(try! Regex(" {2,}"), with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
