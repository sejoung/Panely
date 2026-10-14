import CoreGraphics
import Foundation

/// How the pages of a book are cut into units of OCR work.
///
/// - `page`: each page on its own — right for paged manga, where a page is a
///   self-contained layout.
/// - `strip`: the pages laid end to end the way the vertical (webtoon) layout
///   shows them, read in overlapping bands. Webtoons are often distributed
///   as short slices (e.g. 720 × 576), and a balloon cut by a slice boundary
///   reads as two garbled fragments when each file is analyzed alone — in one
///   test episode 62% of balloons were cut. Reading the strip puts them back
///   together.
nonisolated enum TranslationScope: String, Codable, Sendable {
    case page
    case strip
}

/// Pages laid out top to bottom, centred horizontally — the same geometry
/// `ImageStackView` uses for the vertical layout, so strip coordinates map
/// straight onto what's on screen.
nonisolated struct StripLayout: Equatable, Sendable {
    let pageSizes: [CGSize]
    let width: CGFloat
    let pageTops: [CGFloat]
    let height: CGFloat

    init(pageSizes: [CGSize]) {
        self.pageSizes = pageSizes
        width = pageSizes.map(\.width).max() ?? 0
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for size in pageSizes {
            tops.append(y)
            y += size.height
        }
        pageTops = tops
        height = y
    }

    func pageRect(_ index: Int) -> CGRect {
        let size = pageSizes[index]
        return CGRect(x: (width - size.width) / 2, y: pageTops[index], width: size.width, height: size.height)
    }

    /// Index of the page covering strip position `y` (clamped to the strip).
    func page(containingY y: CGFloat) -> Int {
        guard !pageTops.isEmpty else { return 0 }
        var low = 0
        var high = pageTops.count
        while low < high {
            let mid = (low + high) / 2
            if pageTops[mid] <= y { low = mid + 1 } else { high = mid }
        }
        return max(0, min(pageTops.count - 1, low - 1))
    }

    /// Pages overlapping `range` (half-open).
    func pages(intersecting range: Range<CGFloat>) -> [Int] {
        guard !pageSizes.isEmpty, !range.isEmpty else { return [] }
        let first = page(containingY: range.lowerBound)
        let last = page(containingY: max(range.lowerBound, range.upperBound - 0.001))
        return Array(first...last).filter { pageSizes[$0].height > 0 }
    }
}

/// A horizontal band of the strip, read as one OCR image. `ownedRange` is the
/// part of the strip this band is responsible for: owned ranges of successive
/// bands tile the strip exactly, and each sits at least half an overlap away
/// from the band's seams — so any balloon up to one overlap tall whose centre
/// is owned here is also whole here.
nonisolated struct StripBand: Equatable, Sendable {
    let top: CGFloat
    let height: CGFloat
    let ownedRange: Range<CGFloat>
    let isFirst: Bool
    let isLast: Bool
}

/// One unit of OCR work and the pages whose balloons it can produce.
nonisolated struct TranslationUnit: Equatable, Sendable, Identifiable {
    let id: Int
    let pageIndices: [Int]
    /// `nil` in `.page` scope.
    let band: StripBand?
}

/// The units of work for a book and the bookkeeping to schedule them:
/// which unit comes next given where the reader is, and which pages are
/// finished once a set of units is done.
nonisolated struct TranslationPlan: Sendable {
    let scope: TranslationScope
    let units: [TranslationUnit]
    let pageCount: Int
    /// Strip geometry (`.strip` only).
    let layout: StripLayout?

    static func pages(count: Int) -> TranslationPlan {
        TranslationPlan(
            scope: .page,
            units: (0..<count).map { TranslationUnit(id: $0, pageIndices: [$0], band: nil) },
            pageCount: count,
            layout: nil
        )
    }

    static func strip(_ layout: StripLayout) -> TranslationPlan {
        let bandHeight = OCRTiling.tileHeight(forWidth: Int(layout.width))
        let overlap = bandHeight * 5 / 12
        let tiles = OCRTiling.tiles(forHeight: Int(layout.height.rounded(.up)), tileHeight: bandHeight, overlap: overlap)
        let units = tiles.enumerated().map { index, tile -> TranslationUnit in
            let isFirst = index == 0
            let isLast = index == tiles.count - 1
            let top = CGFloat(tile.top)
            let lower = isFirst ? 0 : top + CGFloat(overlap) / 2
            let upper = isLast ? layout.height : top + CGFloat(tile.height) - CGFloat(overlap) / 2
            let band = StripBand(top: top, height: CGFloat(tile.height), ownedRange: lower..<upper, isFirst: isFirst, isLast: isLast)
            return TranslationUnit(id: index, pageIndices: layout.pages(intersecting: band.ownedRange), band: band)
        }
        return TranslationPlan(scope: .strip, units: units, pageCount: layout.pageSizes.count, layout: layout)
    }

    /// The next unit to work on: the first remaining unit that reaches the
    /// page being read or beyond, else the first remaining one before it.
    func nextUnit(excluding finished: Set<Int>, focusPage: Int) -> TranslationUnit? {
        let remaining = units.filter { !finished.contains($0.id) }
        return remaining.first { ($0.pageIndices.last ?? -1) >= focusPage } ?? remaining.first
    }

    /// Units that have to run for `page` to be complete.
    func units(coveringPage page: Int) -> [TranslationUnit] {
        units.filter { $0.pageIndices.contains(page) }
    }

    /// Pages all of whose units are finished.
    func completedPages(finishedUnits: Set<Int>) -> Set<Int> {
        var complete = Set(0..<pageCount)
        for unit in units where !finishedUnits.contains(unit.id) {
            complete.subtract(unit.pageIndices)
        }
        return complete
    }

    /// Units with nothing left to do because every page they feed is
    /// already complete (e.g. loaded from the cache).
    func unitsAlreadyDone(completePages: Set<Int>) -> Set<Int> {
        Set(units.filter { !$0.pageIndices.isEmpty && $0.pageIndices.allSatisfy(completePages.contains) }.map(\.id))
    }
}
