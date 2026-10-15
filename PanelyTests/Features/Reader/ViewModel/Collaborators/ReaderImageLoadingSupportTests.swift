import Testing
@testable import Panely

struct ReaderImageLoadingSupportTests {
    @Test func initialWindowClampsToPageBounds() {
        let window = ReaderVerticalImageWindow(pageCount: 5)

        #expect(window.initialIndices(around: 0, excluding: []) == [0, 1, 2, 3])
        #expect(window.initialIndices(around: 4, excluding: [4]) == [1, 2, 3])
    }

    @Test func visibleRangeLoadWindowSkipsLoadedPages() {
        let window = ReaderVerticalImageWindow(pageCount: 10)

        let indices = window.loadIndices(forVisibleRange: 4..<6, excluding: [3, 4])

        #expect(indices == [2, 5, 6, 7])
    }

    @Test func keepRangeClampsToLoadedImageCount() {
        let window = ReaderVerticalImageWindow(pageCount: 100)

        #expect(window.keepRange(forVisibleRange: 0..<2, loadedImageCount: 5) == 0..<5)
    }

    // MARK: - evictionIndices

    @Test func evictionUnderBudgetDropsOnlyPagesOutsideKeepRange() {
        let window = ReaderVerticalImageWindow(pageCount: 100)
        // Keep range for 40..<42 is 30..<52.
        let loaded: Set<Int> = [10, 29, 30, 40, 41, 51, 52, 90]

        let evicted = window.evictionIndices(
            forVisibleRange: 40..<42,
            loaded: loaded,
            loadedImageCount: 100,
            byteBudget: .max,
            cost: { _ in 1 }
        )

        #expect(evicted == [10, 29, 52, 90])
    }

    /// Over budget, the farthest pages inside the keep range go first, until
    /// what's left fits.
    @Test func evictionOverBudgetDropsFarthestPagesFirst() {
        let window = ReaderVerticalImageWindow(pageCount: 100)
        let loaded = Set(30..<52)

        let evicted = window.evictionIndices(
            forVisibleRange: 40..<42,
            loaded: loaded,
            loadedImageCount: 100,
            byteBudget: 10,
            cost: { _ in 1 }
        )

        // 22 kept pages at cost 1, budget 10 → 12 evicted, farthest first:
        // distance 10 (30), 9 (31), …, ending at the distance-5 pair (35, 46).
        #expect(evicted.count == 12)
        #expect(Set(evicted) == Set([30, 31, 32, 33, 34, 35, 46, 47, 48, 49, 50, 51]))
    }

    /// Visible pages and their `visibleRangeBuffer` neighbours are never
    /// evicted — even when they alone blow the budget — or `loadIndices`
    /// would re-decode them on the very next scroll tick.
    @Test func evictionNeverDropsVisiblePagesOrLoadBuffer() {
        let window = ReaderVerticalImageWindow(pageCount: 100)
        let loaded = Set(30..<52)

        let evicted = window.evictionIndices(
            forVisibleRange: 40..<42,
            loaded: loaded,
            loadedImageCount: 100,
            byteBudget: 0,
            cost: { _ in 1_000_000 }
        )

        let buffer = ReaderImageLoadingPolicy.visibleRangeBuffer
        let protected = Set((40 - buffer)..<(42 + buffer))
        #expect(Set(evicted).isDisjoint(with: protected))
        #expect(Set(evicted) == loaded.subtracting(protected))
    }

    /// The budget is measured in bytes, so big pages evict sooner than small.
    @Test func evictionWeighsPagesByCost() {
        let window = ReaderVerticalImageWindow(pageCount: 100)
        let loaded: Set<Int> = [32, 40, 41, 47]

        let evicted = window.evictionIndices(
            forVisibleRange: 40..<42,
            loaded: loaded,
            loadedImageCount: 100,
            byteBudget: 300,
            cost: { $0 == 47 ? 1_000 : 100 }
        )

        // Dropping 32 (farthest, cheap) still leaves 1_200 > 300, so 47
        // goes too; the visible pair then fits.
        #expect(evicted == [32, 47])
    }
}
