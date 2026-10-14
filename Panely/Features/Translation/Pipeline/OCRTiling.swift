import CoreGraphics
import Foundation

/// One block of text Vision found, in page pixels (top-left origin).
nonisolated struct TextRegion: Equatable, Sendable {
    var text: String
    var rect: CGRect
    var isVertical: Bool
    /// Narrowest line's width (vertical text) or height (horizontal text).
    var glyphSize: CGFloat
}

/// Splitting tall pages for OCR.
///
/// Vision scales its input down to a working size, so a webtoon strip
/// (1600 × 21000 px) handed over whole comes back with *no* text at all — the
/// glyphs shrink to a few pixels. Tall pages are cut into overlapping bands
/// instead. A balloon crossing a seam is cut in one band but whole in its
/// neighbour (the overlap is taller than any balloon), so cut results are
/// dropped and the duplicates the overlap produces are merged.
nonisolated enum OCRTiling {
    struct Tile: Equatable, Sendable {
        let top: Int
        let height: Int
    }

    static let minimumTileHeight = 2400

    /// Band height for a page `width` px wide — about 1.5 screens of a strip,
    /// never so short that ordinary text gets cut often.
    static func tileHeight(forWidth width: Int) -> Int {
        max(minimumTileHeight, width * 3 / 2)
    }

    /// Ordinary comic pages (even tall ones) go through whole; only strips
    /// clearly taller than a page are tiled.
    static func needsTiling(width: Int, height: Int) -> Bool {
        height > max(tileHeight(forWidth: width), width * 2)
    }

    /// Overlapping bands covering `0..<height`, top to bottom.
    static func tiles(forHeight height: Int, tileHeight: Int, overlap: Int) -> [Tile] {
        guard height > 0, tileHeight > overlap, overlap >= 0 else { return [] }
        guard height > tileHeight else { return [Tile(top: 0, height: height)] }
        var result: [Tile] = []
        var top = 0
        while true {
            let bandHeight = min(tileHeight, height - top)
            result.append(Tile(top: top, height: bandHeight))
            if top + bandHeight >= height { break }
            top += tileHeight - overlap
        }
        return result
    }

    /// Bands for a page of the given size: one band when it doesn't need
    /// tiling. The overlap is ~40% of a band, comfortably taller than a
    /// balloon.
    static func tiles(width: Int, height: Int) -> [Tile] {
        guard needsTiling(width: width, height: height) else {
            return height > 0 ? [Tile(top: 0, height: height)] : []
        }
        let bandHeight = tileHeight(forWidth: width)
        return tiles(forHeight: height, tileHeight: bandHeight, overlap: bandHeight * 5 / 12)
    }

    /// Whether a region found in a band (band-local coordinates) is whole —
    /// i.e. doesn't touch a seam shared with a neighbouring band.
    static func isWhole(_ rect: CGRect, bandHeight: Int, isFirst: Bool, isLast: Bool, margin: CGFloat = 6) -> Bool {
        if !isFirst && rect.minY < margin { return false }
        if !isLast && rect.maxY > CGFloat(bandHeight) - margin { return false }
        return true
    }

    /// Merge regions seen whole by two overlapping bands, keeping the one with
    /// more text. Output is in reading order (top to bottom).
    static func deduplicate(_ regions: [TextRegion]) -> [TextRegion] {
        var kept: [TextRegion] = []
        for region in regions.sorted(by: { $0.text.count > $1.text.count }) {
            let duplicate = kept.contains { overlapFraction($0.rect, region.rect) > 0.5 }
            if !duplicate { kept.append(region) }
        }
        return kept.sorted { $0.rect.minY < $1.rect.minY }
    }

    /// Intersection area relative to the smaller rect.
    static func overlapFraction(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        guard smaller > 0 else { return 0 }
        return intersection.width * intersection.height / smaller
    }
}
