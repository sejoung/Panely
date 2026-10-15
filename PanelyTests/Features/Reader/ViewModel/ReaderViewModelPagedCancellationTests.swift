import Testing
import AppKit
import Foundation
@testable import Panely

/// Paged navigation through the view model while a superseded page read is
/// still in flight, held at a `ReadGate` so the overlap is guaranteed.
@MainActor
struct ReaderViewModelPagedCancellationTests {
    /// Paging past a slow page: the refresh for it is cancelled all the way
    /// down to the archive read (so the read can stop early), its late
    /// result never reaches the screen, and the cancellation is no error.
    @Test func pagingPastASlowPageCancelsItsReadAndShowsTheNewPage() async throws {
        let slow = ReadGate()
        defer { slow.open() }
        let open = ReadGate(open: true)
        let pages = [
            try GatedArchiveReader.page(named: "0.png", size: CGSize(width: 40, height: 60), gate: open),
            try GatedArchiveReader.page(named: "1.png", size: CGSize(width: 50, height: 70), gate: slow),
            try GatedArchiveReader.page(named: "2.png", size: CGSize(width: 60, height: 80), gate: open),
        ]
        let vm = makeTestViewModel()
        vm.source = ComicSource(title: "Slow", pages: pages)
        vm.layout = .single

        vm.jump(to: 1)
        let slowRefresh = try #require(vm.pagedRefreshTask)
        try await waitUntil { slow.arrivals >= 1 }

        vm.jump(to: 2)
        let finalRefresh = try #require(vm.pagedRefreshTask)
        await finalRefresh.value
        #expect(vm.imageLoader.currentPageIDs == [pages[2].id])

        slow.open()
        await slowRefresh.value

        // `.first`: preloading the neighbours may read page 1 again, uncancelled.
        #expect(slow.sawCancellation.first == true, "the superseded page read should run cancelled")
        #expect(vm.imageLoader.currentPageIDs == [pages[2].id])
        #expect(vm.currentImages.map(\.size) == [CGSize(width: 60, height: 80)])
        #expect(vm.errorMessage == nil)
    }
}
