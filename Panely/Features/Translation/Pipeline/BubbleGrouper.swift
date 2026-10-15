import CoreGraphics
import Foundation

/// A balloon's worth of source text, ready to translate.
nonisolated struct BubbleDraft: Equatable, Sendable {
    var rect: CGRect
    var glyphSize: CGFloat
    var isVertical: Bool
    var source: String
    /// The detected balloon around the text, when there is one — room the
    /// translation can use beyond the original's own lines.
    var balloonRect: CGRect? = nil
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
///
/// With balloons from `BalloonDetector`, the detector decides instead: text in
/// the same detected balloon is one balloon, whatever its layout, and text in
/// two balloons stays apart however close. Text the detector put in no balloon
/// or text box is artwork OCR misread (a drawn "조잘조잘", a pattern) and is
/// dropped — unless it's a sentence's worth, which the detector more likely
/// missed. A page where the detector found nothing at all is grouped by the
/// rules, as if there were no detector. (Measured on 48 pages of three
/// books: all eight dropped blocks were sound effects or noise.)
nonisolated enum BubbleGrouper {
    /// Text outside every detection this long is kept anyway.
    static let keptOutsideLength = 8

    static func group(_ regions: [TextRegion], language: TranslationLanguage, detections: [DetectedRegion]? = nil) -> [BubbleDraft] {
        let candidates = regions.compactMap { region -> TextRegion? in
            var cleaned = region
            cleaned.text = TranslationTextNormalizer.normalize(region.text, language: language)
            guard !cleaned.text.isEmpty, language.containsOwnScript(cleaned.text) else { return nil }
            return cleaned
        }
        guard let detections, !detections.isEmpty else { return groupByLayout(candidates, language: language) }

        var byContainer: [Int: [TextRegion]] = [:]
        var outside: [TextRegion] = []
        for region in candidates {
            if let container = container(of: region.rect, in: detections) {
                byContainer[container, default: []].append(region)
            } else if region.text.filter(\.isLetter).count >= keptOutsideLength {
                outside.append(region)
            }
        }
        let detected = byContainer.map { container, parts in
            var draft = makeDraft(from: parts, language: language)
            if detections[container].kind == .balloon {
                draft.balloonRect = detections[container].rect
            }
            return draft
        }
        return sortedInReadingOrder(detected + groupByLayout(outside, language: language))
    }

    /// The detection a text region belongs to, as an index into
    /// `detections`. The text box covering it most decides: text inside a
    /// balloon goes with the balloon holding that box, text outside balloons
    /// with its own box — so an aside drawn beside a round balloon, inside
    /// its bounding box, stays apart. Without a text box, the smallest
    /// balloon covering it.
    static func container(of rect: CGRect, in detections: [DetectedRegion]) -> Int? {
        func smallest(_ indices: [Int]) -> Int? {
            indices.min { area(detections[$0].rect) < area(detections[$1].rect) }
        }
        let textBoxes = detections.indices.filter {
            detections[$0].kind != .balloon && coverage(of: rect, by: detections[$0].rect) >= 0.5
        }
        if let box = textBoxes.max(by: { coverage(of: rect, by: detections[$0].rect) < coverage(of: rect, by: detections[$1].rect) }) {
            guard detections[box].kind == .textInBalloon else { return box }
            let holder = smallest(detections.indices.filter {
                detections[$0].kind == .balloon && coverage(of: detections[box].rect, by: detections[$0].rect) >= 0.5
            })
            return holder ?? box
        }
        return smallest(detections.indices.filter {
            detections[$0].kind == .balloon && coverage(of: rect, by: detections[$0].rect) >= 0.5
        })
    }

    /// The share of `rect`'s area inside `container`.
    private static func coverage(of rect: CGRect, by container: CGRect) -> CGFloat {
        let intersection = rect.intersection(container)
        guard !intersection.isNull, area(rect) > 0 else { return 0 }
        return area(intersection) / area(rect)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private static func groupByLayout(_ candidates: [TextRegion], language: TranslationLanguage) -> [BubbleDraft] {
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

        return sortedInReadingOrder(groups.values.map { makeDraft(from: $0, language: language) })
    }

    private static func sortedInReadingOrder(_ drafts: [BubbleDraft]) -> [BubbleDraft] {
        drafts.sorted { a, b in
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
        // Detected balloons can hold both (a vertical line beside a
        // horizontal aside); the balloon reads the way most of it does.
        let isVertical = parts.filter(\.isVertical).count * 2 > parts.count
        // Reading order inside the balloon, from where the parts sit: one
        // above the other, top to bottom; side by side (overlapping in
        // height, like columns), right to left in Japanese and Chinese,
        // left to right otherwise. Not from OCR's direction, which flips for
        // the same columns from one read to the next.
        let rightToLeft = isVertical || language.isWrittenVertically
        let ordered = parts.sorted { a, b in
            let overlapY = min(a.rect.maxY, b.rect.maxY) - max(a.rect.minY, b.rect.minY)
            if overlapY > 0.3 * min(a.rect.height, b.rect.height) {
                return rightToLeft ? a.rect.midX > b.rect.midX : a.rect.midX < b.rect.midX
            }
            return a.rect.minY < b.rect.minY
        }
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
