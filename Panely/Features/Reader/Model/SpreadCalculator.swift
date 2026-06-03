import Foundation

/// Single source of truth for how page indices group into the visible
/// "spread" in paged layouts. Centralizes the parity math that used to be
/// scattered across navigation (`next`/`previous`/`jump`), the image loader's
/// visible span, and position restore — keeping them from drifting out of
/// sync, which is exactly what makes double-page pairing feel "off by one".
///
/// `step` is the layout's navigation step: 1 for single/vertical, 2 for
/// double. `coverAlone` shifts double-page pairing by one so the first page
/// stands alone before pairs begin:
///
///     coverAlone == false:  (0,1) (2,3) (4,5) …
///     coverAlone == true:    0  | (1,2) (3,4) …
///
/// Most scanned books put a standalone cover at page 0 with the true facing
/// spreads at (2,3)(4,5)…, so the default pairing splits every real spread
/// across two viewer spreads. `coverAlone` realigns them. It only affects
/// `step >= 2`; single/vertical always returns one page per "spread".
enum SpreadCalculator {

    /// The page-index range of the spread that contains `index`.
    /// Clamps `index` into `0..<pageCount`; returns `0..<0` for an empty source.
    /// The final spread is naturally a singleton when an odd page count leaves
    /// one page over.
    static func spread(
        containing index: Int,
        pageCount: Int,
        step: Int,
        coverAlone: Bool
    ) -> Range<Int> {
        guard pageCount > 0, step > 0 else { return 0..<0 }
        let clampedIndex = min(max(index, 0), pageCount - 1)

        // `offset` is the lone-cover shift: pairs begin at index `offset`
        // instead of 0. Only meaningful in multi-page (double) layouts.
        let offset = (coverAlone && step >= 2) ? 1 : 0

        let start: Int
        if clampedIndex < offset {
            start = 0
        } else {
            start = offset + ((clampedIndex - offset) / step) * step
        }

        // The standalone cover (start < offset) is length 1; every other
        // spread is `step` pages, clamped so the tail doesn't run past the end.
        let length = start < offset ? 1 : min(step, pageCount - start)
        return start ..< (start + length)
    }

    /// Start index of the spread *after* the one containing `index`, or `nil`
    /// when `index` is already in the final spread. Mirrors what `next()`
    /// should land on.
    static func nextStart(
        from index: Int,
        pageCount: Int,
        step: Int,
        coverAlone: Bool
    ) -> Int? {
        let current = spread(containing: index, pageCount: pageCount, step: step, coverAlone: coverAlone)
        let next = current.upperBound
        return next < pageCount ? next : nil
    }

    /// Start index of the spread *before* the one containing `index`, or `nil`
    /// when `index` is already in the first spread. Mirrors what `previous()`
    /// should land on.
    static func previousStart(
        from index: Int,
        pageCount: Int,
        step: Int,
        coverAlone: Bool
    ) -> Int? {
        let current = spread(containing: index, pageCount: pageCount, step: step, coverAlone: coverAlone)
        guard current.lowerBound > 0 else { return nil }
        return spread(containing: current.lowerBound - 1, pageCount: pageCount, step: step, coverAlone: coverAlone).lowerBound
    }
}
