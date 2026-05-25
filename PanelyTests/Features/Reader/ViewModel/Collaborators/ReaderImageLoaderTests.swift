import Testing
import Foundation
import AppKit
@testable import Panely

/// Focused tests for `ReaderImageLoader`. The full async `refresh(...)` /
/// `setVisibleRange(...)` paths are exercised end-to-end by
/// `ReaderViewModelPagedModeTests` and `ReaderViewModelVerticalModeTests`;
/// this suite covers the synchronous state-management and pure helpers
/// that don't need a real source.
@MainActor
struct ReaderImageLoaderTests {

    // MARK: - Lifecycle

    @Test func resetClearsAllState() {
        let loader = ReaderImageLoader()
        loader.currentImages = [ReaderImageLoader.makePlaceholder(size: CGSize(width: 100, height: 150))]
        loader.pageDimensions = [CGSize(width: 100, height: 150)]

        loader.reset()

        #expect(loader.currentImages.isEmpty)
        #expect(loader.pageDimensions.isEmpty)
        #expect(loader.loadedPageIndices.isEmpty)
    }

    @Test func prepareForLayoutRebuildClearsImagesButLeavesDimensions() {
        let loader = ReaderImageLoader()
        loader.currentImages = [
            ReaderImageLoader.makePlaceholder(size: CGSize(width: 100, height: 150)),
            ReaderImageLoader.makePlaceholder(size: CGSize(width: 100, height: 150)),
        ]
        loader.pageDimensions = [
            CGSize(width: 100, height: 150),
            CGSize(width: 100, height: 150),
        ]

        loader.prepareForLayoutRebuild()

        // Images go (callers will repopulate via refresh()) but dimensions
        // stay so the strip's frame doesn't collapse mid-transition.
        #expect(loader.currentImages.isEmpty)
        #expect(loader.pageDimensions.count == 2)
    }

    @Test func cancelPreloadIsSafeWhenNoTaskInFlight() {
        let loader = ReaderImageLoader()
        // No preload task has been scheduled — cancel must no-op cleanly.
        loader.cancelPreload()
    }

    @Test func cancelBackgroundWorkIsSafeWhenNoTaskInFlight() {
        let loader = ReaderImageLoader()
        loader.cancelBackgroundWork()
    }

    @Test func pagedRefreshShowsErrorPlaceholderForFailedImage() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let badImage = root.appendingPathComponent("bad.jpg")
        try Data("not an image".utf8).write(to: badImage)

        let loader = ReaderImageLoader()
        var errors: [String] = []
        await loader.refresh(
            source: ComicSource(
                title: "Broken",
                pages: [ComicPage(source: .file(badImage), displayName: "bad.jpg")]
            ),
            layout: .single,
            currentPageIndex: 0,
            navigationStep: 1,
            isCancelled: { false },
            onError: { errors.append($0) }
        )

        #expect(loader.currentImages.count == 1)
        #expect(loader.currentImages[0].size == CGSize(width: 1000, height: 1500))
        #expect(errors == ["Failed to load bad.jpg"])
    }

    // MARK: - estimatedBitmapCost

    @Test func bitmapCostUsesPixelDimensionsForBitmapReps() throws {
        // 2× backing: an image whose `size` reports 100×100 in points but
        // whose bitmap rep is 200×200 in pixels. The point-based formula
        // would under-price it by 4×; the pixel-based path is the whole
        // reason this helper exists.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 200,
            pixelsHigh: 200,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let unwrapped = try #require(rep)
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.addRepresentation(unwrapped)

        let cost = ReaderImageLoader.estimatedBitmapCost(of: image)
        #expect(cost == 200 * 200 * 4)
    }

    @Test func bitmapCostFallsBackToPointSizeWhenNoBitmapRep() {
        // Custom drawing-handler images report 0 pixels in their rep, so
        // the helper falls back to `size × 4`. The placeholder we generate
        // for vertical-strip slots hits exactly this path.
        let size = CGSize(width: 100, height: 150)
        let placeholder = ReaderImageLoader.makePlaceholder(size: size)
        let cost = ReaderImageLoader.estimatedBitmapCost(of: placeholder)
        #expect(cost == Int(size.width * size.height * 4))
    }

    // MARK: - Placeholders + concurrency cap

    @Test func makePlaceholderReturnsImageOfRequestedSize() {
        let size = CGSize(width: 1200, height: 1800)
        let placeholder = ReaderImageLoader.makePlaceholder(size: size)
        #expect(placeholder.size == size)
    }

    @Test func lazyConcurrencyLimitClampsToReasonableRange() {
        // The decode pool sizing should never go below 2 (would serialize
        // on dual-core hosts) or above 8 (diminishing returns + per-task
        // overhead on monster CPUs).
        let limit = ReaderImageLoader.lazyConcurrencyLimit
        #expect(limit >= 2)
        #expect(limit <= 8)
    }
}
