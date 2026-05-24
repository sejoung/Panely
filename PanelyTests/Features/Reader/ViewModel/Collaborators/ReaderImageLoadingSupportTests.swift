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
}
