import Testing
import Foundation
import AppKit
@testable import Panely

/// The reading position and progress the user leaves behind must survive
/// every way of leaving a book: switching to another one mid-debounce,
/// reopening the same book before its write lands, the app resigning active,
/// and the app quitting. Each test reads back through *fresh* stores built
/// on the same key-value store — what the next launch would see — so a write
/// that only reached an in-memory mirror doesn't count.
@MainActor
@Suite(.serialized)
struct PositionPersistenceSafetyTests {

    @Test func resignActiveLandsThePendingPageAndProgress() {
        let defaults = InMemoryKeyValueStore()
        let url = URL(fileURLWithPath: "/tmp/resign-\(UUID().uuidString).cbz")
        let vm = makeViewModel(url: url, defaults: defaults, pageCount: 10)

        vm.currentPageIndex = 6
        // Still waiting out the 2 s debounce: nothing on "disk" yet.
        #expect(vm.positions.saveDebouncer.isPending)
        #expect(vm.readingProgress.saveDebouncer.isPending)
        #expect(freshPosition(of: url, in: defaults) == 0)
        #expect(freshProgress(of: url, in: defaults) == nil)

        NotificationCenter.default.post(
            name: NSApplication.willResignActiveNotification,
            object: NSApplication.shared
        )

        #expect(freshPosition(of: url, in: defaults) == 6)
        let progress = freshProgress(of: url, in: defaults)
        #expect(progress?.page == 6)
        #expect(progress?.total == 10)
        #expect(!vm.positions.saveDebouncer.isPending)
        #expect(!vm.readingProgress.saveDebouncer.isPending)
    }

    @Test func terminateLandsProgressAsWellAsPosition() {
        let defaults = InMemoryKeyValueStore()
        let url = URL(fileURLWithPath: "/tmp/terminate-progress-\(UUID().uuidString).cbz")
        let vm = makeViewModel(url: url, defaults: defaults, pageCount: 10)
        vm.currentPageIndex = 7

        // `terminate(_:)` exits without another run-loop turn: the progress
        // record (badges, Continue Reading) has to land inline too.
        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification,
            object: NSApplication.shared
        )

        #expect(freshPosition(of: url, in: defaults) == 7)
        #expect(freshProgress(of: url, in: defaults)?.page == 7)
        #expect(freshProgress(of: url, in: defaults)?.total == 10)
    }

    @Test func rapidPageTurnsThenBookSwitchKeepEveryBooksLastPage() async throws {
        let library = try makeLibrary(books: ["Alpha": 10, "Beta": 6])
        defer { try? FileManager.default.removeItem(at: library) }
        let alpha = library.appendingPathComponent("Alpha", isDirectory: true)
        let beta = library.appendingPathComponent("Beta", isDirectory: true)
        let defaults = InMemoryKeyValueStore()
        let vm = makeTestViewModel(keyValueStore: defaults)
        vm.layout = .single

        await vm.load(url: alpha)
        for page in 1...7 { vm.jump(to: page) }
        await vm.load(url: beta)
        vm.jump(to: 3)

        // Alpha's last page landed when Beta's first write arrived; Beta's
        // own last page is still pending, and lands on resign-active.
        #expect(freshPosition(of: alpha, in: defaults) == 7)
        #expect(freshProgress(of: alpha, in: defaults)?.page == 7)
        vm.flushPendingPositionWrites()
        #expect(freshPosition(of: beta, in: defaults) == 3)
        #expect(freshProgress(of: beta, in: defaults)?.page == 3)
        #expect(freshProgress(of: beta, in: defaults)?.total == 6)
        // Switching never wrote one book's page under the other's key.
        #expect(freshPosition(of: alpha, in: defaults) == 7)
        #expect(freshProgress(of: alpha, in: defaults)?.total == 10)

        await vm.load(url: alpha)
        #expect(vm.currentPageIndex == 7)
    }

    @Test func reopeningWithinTheDebounceWindowRestoresThePageJustLeft() async throws {
        let library = try makeLibrary(books: ["Alpha": 10])
        defer { try? FileManager.default.removeItem(at: library) }
        let alpha = library.appendingPathComponent("Alpha", isDirectory: true)
        let defaults = InMemoryKeyValueStore()
        let vm = makeTestViewModel(keyValueStore: defaults)
        vm.layout = .single

        await vm.load(url: alpha)
        vm.jump(to: 2)
        vm.flushPendingPositionWrites()
        vm.jump(to: 8)  // still debounced
        #expect(vm.positions.saveDebouncer.isPending)

        // Reload the same book (e.g. a source-change reload) before the
        // write lands: it must open on page 8, not the landed page 2.
        await vm.load(url: alpha)
        #expect(vm.currentPageIndex == 8)
        vm.flushPendingPositionWrites()
        #expect(freshPosition(of: alpha, in: defaults) == 8)
    }

    @Test func terminateLandsAPendingWriteForABookThatIsNoLongerOpen() async throws {
        let library = try makeLibrary(books: ["Alpha": 10])
        defer { try? FileManager.default.removeItem(at: library) }
        let alpha = library.appendingPathComponent("Alpha", isDirectory: true)
        let empty = library.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let defaults = InMemoryKeyValueStore()
        let vm = makeTestViewModel(keyValueStore: defaults)
        vm.layout = .single

        await vm.load(url: alpha)
        vm.jump(to: 6)  // still debounced
        // Picking something that can't be read clears the open book while
        // Alpha's last page is still waiting out the debounce…
        await vm.load(url: empty)
        #expect(vm.currentSourceURL == nil)

        // …and quitting right then must not lose it.
        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification,
            object: NSApplication.shared
        )

        #expect(freshPosition(of: alpha, in: defaults) == 6)
        #expect(freshProgress(of: alpha, in: defaults)?.page == 6)
    }

    // MARK: - Helpers

    private func makeViewModel(url: URL, defaults: InMemoryKeyValueStore, pageCount: Int) -> ReaderViewModel {
        let vm = makeTestViewModel(keyValueStore: defaults)
        vm.currentSourceURL = url
        vm.source = ComicSource(title: "t", pages: Fixture.makeImagePages(count: pageCount))
        return vm
    }

    private func freshPosition(of url: URL, in defaults: InMemoryKeyValueStore) -> Int {
        ReaderPositionStore(defaults: defaults).restoredIndex(for: url, opened: nil, tempRoot: nil)
    }

    private func freshProgress(of url: URL, in defaults: InMemoryKeyValueStore) -> ReadingProgress? {
        ReadingProgressStore(defaults: defaults).progress(for: url, opened: nil, tempRoot: nil)
    }

    /// A folder of image-folder books: `<library>/<name>/000.png…`.
    private func makeLibrary(books: [String: Int]) throws -> URL {
        let library = try Fixture.makeTempDir()
        let png = try Fixture.makePNG(width: 10, height: 10)
        for (name, pageCount) in books {
            let book = library.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
            for index in 0..<pageCount {
                try png.write(to: book.appendingPathComponent(String(format: "%03d.png", index)))
            }
        }
        return library
    }
}
