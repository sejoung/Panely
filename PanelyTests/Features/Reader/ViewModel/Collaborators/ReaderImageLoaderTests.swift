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

    @Test func verticalRefreshTracksFailedPageSeparatelyFromLoaded() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let good0 = root.appendingPathComponent("0.png")
        let bad = root.appendingPathComponent("1.png")
        let good2 = root.appendingPathComponent("2.png")
        try Fixture.makePNG(width: 10, height: 10).write(to: good0)
        try Data("not an image".utf8).write(to: bad)
        try Fixture.makePNG(width: 10, height: 10).write(to: good2)

        let loader = ReaderImageLoader()
        var errors: [String] = []
        await loader.refresh(
            source: ComicSource(title: "Strip", pages: [
                ComicPage(source: .file(good0), displayName: "0.png"),
                ComicPage(source: .file(bad), displayName: "1.png"),
                ComicPage(source: .file(good2), displayName: "2.png"),
            ]),
            layout: .vertical,
            currentPageIndex: 0,
            navigationStep: 1,
            isCancelled: { false },
            onError: { errors.append($0) }
        )

        // The decoded pages are "loaded"; the broken one is tracked as
        // "failed" — NOT loaded — so it stays eligible to retry when it
        // scrolls back into the window instead of sticking forever.
        #expect(loader.loadedPageIndices == [0, 2])
        #expect(loader.failedPageIndices == [1])
        #expect(errors == ["Failed to load 1.png"])
        // The failed slot still shows the error placeholder, not a void.
        #expect(loader.currentImages.count == 3)
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

    // MARK: - Cache cost limit (RAM-scaled, clamped)

    @Test func costLimitClampsUpForLowMemoryHosts() {
        // 512 MB host → 512/16 = 32 MB target, below the floor → clamps up.
        let limit = ReaderImageMemoryCache.costLimit(physicalMemory: 512 * 1024 * 1024)
        #expect(limit == Int(ReaderImageMemoryCache.minCostLimit))
    }

    @Test func costLimitClampsDownForHighMemoryHosts() {
        // 256 GB host → 16 GB target, above the ceiling → clamps down.
        let limit = ReaderImageMemoryCache.costLimit(physicalMemory: 256 * 1024 * 1024 * 1024)
        #expect(limit == Int(ReaderImageMemoryCache.maxCostLimit))
    }

    @Test func costLimitScalesLinearlyBetweenBounds() {
        // 8 GB host → 8/16 = 512 MB, inside [150 MB, 1 GB] → returned as-is.
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        let limit = ReaderImageMemoryCache.costLimit(physicalMemory: eightGB)
        #expect(limit == Int(eightGB / 16))
        #expect(UInt64(limit) >= ReaderImageMemoryCache.minCostLimit)
        #expect(UInt64(limit) <= ReaderImageMemoryCache.maxCostLimit)
    }

    @Test func costLimitHonorsExactBoundaries() {
        // target == floor exactly (2.4 GB / 16 = 150 MB) and ceiling exactly
        // (16 GB / 16 = 1 GB) must pass through without over-clamping.
        let atFloor = ReaderImageMemoryCache.costLimit(physicalMemory: ReaderImageMemoryCache.minCostLimit * 16)
        #expect(atFloor == Int(ReaderImageMemoryCache.minCostLimit))

        let atCeiling = ReaderImageMemoryCache.costLimit(physicalMemory: ReaderImageMemoryCache.maxCostLimit * 16)
        #expect(atCeiling == Int(ReaderImageMemoryCache.maxCostLimit))
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
