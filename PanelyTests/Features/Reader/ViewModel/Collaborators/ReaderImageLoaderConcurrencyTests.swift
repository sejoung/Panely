import Testing
import AppKit
import Foundation
@testable import Panely

/// Ordering races in `ReaderImageLoader`, made deterministic with
/// `GatedArchiveReader`: a page read is held at a gate until the test has
/// put the competing work in place, so "the stale decode finishes last" is
/// a fact of the test, not a timing accident.
@MainActor
struct ReaderImageLoaderConcurrencyTests {
    /// Two paged refreshes overlap and the older one finishes last (a slow
    /// page, a cold disk). Its spread must not replace the newer one on
    /// screen — the generation check, independent of task cancellation,
    /// which the loader's own callers don't always use.
    @Test func olderPagedRefreshFinishingLastDoesNotOverwriteNewerSpread() async throws {
        let slow = ReadGate()
        defer { slow.open() }
        let pages = [
            try GatedArchiveReader.page(named: "0.png", size: CGSize(width: 40, height: 60), gate: slow),
            try GatedArchiveReader.page(named: "1.png", size: CGSize(width: 50, height: 70), gate: ReadGate(open: true)),
        ]
        let source = ComicSource(title: "Race", pages: pages)
        let loader = ReaderImageLoader()
        var errors: [String] = []

        func refresh(to index: Int) -> Task<Void, Never> {
            Task {
                await loader.refresh(
                    source: source,
                    layout: .single,
                    currentPageIndex: index,
                    navigationStep: 1,
                    isCancelled: { false },
                    onError: { errors.append($0) }
                )
            }
        }

        let older = refresh(to: 0)
        try await waitUntil { slow.arrivals >= 1 }
        let newer = refresh(to: 1)
        await newer.value
        #expect(loader.currentPageIDs == [pages[1].id])

        slow.open()
        await older.value

        #expect(loader.currentPageIDs == [pages[1].id])
        #expect(loader.currentImages.map(\.size) == [CGSize(width: 50, height: 70)])
        #expect(errors.isEmpty)
    }

    /// Scrolling cancels the previous lazy batch without starting a new
    /// generation. A page whose read was cancelled mid-flight is not a
    /// failed page: no "Failed to load" error, no error placeholder pinned in
    /// `failedPageIndices` — and the replacement batch still loads it.
    @Test func cancelledLazyReadIsNotReportedAsFailure() async throws {
        let gate = ReadGate()
        defer { gate.open() }
        let open = ReadGate(open: true)
        let gatedIndex = 20
        let pages: [ComicPage] = try (0..<30).map { i in
            try GatedArchiveReader.page(
                named: "\(i).png",
                size: CGSize(width: 30, height: 40 + i),
                gate: i == gatedIndex ? gate : open
            )
        }
        let source = ComicSource(title: "Strip", pages: pages)
        let loader = ReaderImageLoader()
        var errors: [String] = []

        await loader.refresh(
            source: source,
            layout: .vertical,
            currentPageIndex: 0,
            navigationStep: 1,
            isCancelled: { false },
            onError: { errors.append($0) }
        )
        #expect(loader.pageDimensions.count == 30)

        // First batch blocks on page 20…
        loader.setVisibleRange(19..<21, source: source, layout: .vertical) { errors.append($0) }
        try await waitUntil { gate.arrivals >= 1 }
        // …a scroll tick supersedes it, then the read completes.
        loader.setVisibleRange(20..<22, source: source, layout: .vertical) { errors.append($0) }
        gate.open()

        try await waitUntil { loader.loadedPageIndices.contains(gatedIndex) }
        #expect(gate.sawCancellation.first == true, "the superseded batch's read should see its cancellation")
        #expect(errors.isEmpty)
        #expect(loader.failedPageIndices.isEmpty)
        // The decoded page, not its gray placeholder (a drawing-handler image
        // with no bitmap rep).
        #expect(loader.currentImages[gatedIndex].representations.contains { $0.pixelsWide > 0 })
    }
}
