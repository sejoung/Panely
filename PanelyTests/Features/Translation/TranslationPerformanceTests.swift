import CoreGraphics
import Foundation
import Testing
@testable import Panely

/// Work a long book or a long job shouldn't repeat or hold up: what's read
/// first, what's read once, what's written at once and what's let go of.
@MainActor
struct TranslationPerformanceTests {
    // MARK: - Reading the cache

    @Test nonisolated func theCacheIsReadNearestTheFocusFirstInBatches() {
        let batches = TranslationController.cacheLoadBatches(indices: Array(0..<1000), focus: 500)
        #expect(batches[0].first == 500)
        #expect(batches[0].count == TranslationController.firstCacheBatch)
        #expect(batches[0].allSatisfy { abs($0 - 500) <= 4 })
        #expect(batches.dropFirst().allSatisfy { $0.count <= TranslationController.cacheBatch })
        #expect(batches.flatMap { $0 }.sorted() == Array(0..<1000), "every page, once")

        #expect(TranslationController.cacheLoadBatches(indices: [], focus: 3).isEmpty)
        #expect(TranslationController.cacheLoadBatches(indices: [7, 1], focus: 0) == [[1, 7]])
        // The focus needn't be cached, or even near anything that is.
        #expect(TranslationController.cacheLoadBatches(indices: [0, 1, 900], focus: 899)[0].first == 900)
    }

    /// The page being read shows from the first write, long before the rest.
    @Test func reopeningABookShowsThePageBeingReadFirst() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 300)
        for page in pages {
            try store.save(makeTranslatedPage("x"), key: TranslationStore.key(pageID: page.id, from: .japanese, to: .korean))
        }
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore(), translator: ScriptedTranslator())
        controller.reload(pages: pages, pageSizes: [], scope: .page, source: .japanese, target: .korean, enabled: true, autoStart: false, focusPage: 150)
        try await waitUntil { controller.hasPages }
        #expect(controller.pages[pages[150].id] != nil)
        #expect(controller.pages.count < pages.count)
        #expect(controller.completedPageIndices.contains(150))

        await controller.cacheTask?.value
        #expect(controller.pages.count == pages.count)
        #expect(controller.completedPageCount == pages.count)
    }

    /// A book closed partway through loading doesn't get the rest.
    @Test func aCacheLoadStopsWithItsBook() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 300)
        for page in pages {
            try store.save(makeTranslatedPage("x"), key: TranslationStore.key(pageID: page.id, from: .japanese, to: .korean))
        }
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore(), translator: ScriptedTranslator())
        controller.reload(pages: pages, pageSizes: [], scope: .page, source: .japanese, target: .korean, enabled: true, autoStart: false, focusPage: 0)
        let task = try #require(controller.cacheTask)
        try await waitUntil { controller.hasPages }
        controller.clear()
        await task.value
        #expect(controller.pages.isEmpty)
        #expect(controller.completedPageIndices.isEmpty)
    }

    // MARK: - What changed

    @Test func theControllerSaysWhichPagesChangedUntilItCannot() async throws {
        let translator = ScriptedTranslator()
        let controller = TranslationController(store: try makeTemporaryTranslationStore(), defaults: InMemoryKeyValueStore(), translator: translator)
        let pages = Fixture.makeImagePages(count: 2)
        let analyzer = StubPageAnalyzer(texts: [0: ["一"], 1: ["二"]])
        controller.makeAnalyzer = { _, _ in analyzer }
        controller.requestStart = {}
        controller.reload(pages: pages, pageSizes: [], scope: .page, source: .japanese, target: .korean, enabled: true, autoStart: false, focusPage: 0)
        await controller.cacheTask?.value
        let start = controller.pagesStamp
        #expect(controller.pagesChanged(since: start) == [])

        controller.start()
        try await waitUntil { !controller.isWorking }
        #expect(controller.pagesStamp > start)
        #expect(controller.pagesChanged(since: start) == Set(pages.map(\.id)))
        #expect(controller.pagesChanged(since: controller.pagesStamp) == [])

        // Everything went at once: no list says so.
        controller.clear()
        #expect(controller.pagesChanged(since: start) == nil)
    }

    /// A page made only of lines seen before is filled in at once, not a
    /// write (and a viewer update) a balloon.
    @Test func reusedLinesAreWrittenTogether() async throws {
        let lines = ["一", "二", "三", "四", "五", "六"]
        let translator = ScriptedTranslator()
        let controller = TranslationController(store: try makeTemporaryTranslationStore(), defaults: InMemoryKeyValueStore(), translator: translator)
        let pages = Fixture.makeImagePages(count: 2)
        let analyzer = StubPageAnalyzer(texts: [0: lines, 1: lines])
        controller.makeAnalyzer = { _, _ in analyzer }
        controller.requestStart = {}
        controller.reload(pages: pages, pageSizes: [], scope: .page, source: .japanese, target: .korean, enabled: true, autoStart: false, focusPage: 0)
        await controller.cacheTask?.value

        // Revision counting only sees the last write, so watch every change.
        var writes = 0
        var last = controller.pageRevisions[pages[1].id]
        controller.start()
        while controller.isWorking {
            let revision = controller.pageRevisions[pages[1].id]
            if revision != last {
                writes += 1
                last = revision
            }
            await Task.yield()
        }
        #expect(translator.requests.map(\.lines) == [lines])
        #expect(controller.pages[pages[1].id]?.bubbles.allSatisfy { $0.translation != nil } == true)
        // Found, filled in, finished: not one per balloon.
        #expect(writes <= 3, "\(writes) writes for page 2")
    }

    // MARK: - Strip sizes

    private func stripPages(_ sizes: [(Int, Int)]) throws -> [ComicPage] {
        let directory = try Fixture.makeTempDir()
        return try sizes.enumerated().map { index, size in
            let url = directory.appendingPathComponent("\(index).png")
            try Fixture.makePNG(width: size.0, height: size.1).write(to: url)
            return ComicPage(source: .file(url), displayName: url.lastPathComponent)
        }
    }

    @Test func pageSizesComeBackInPageOrder() async throws {
        let expected = (1...40).map { ($0 + 1, 41 - $0 + 1) }
        let pages = try stripPages(expected)
        let sizes = await TranslationController.readPageSizes(of: pages)
        #expect(sizes == expected.map { CGSize(width: $0.0, height: $0.1) })
    }

    private func runStripJob(_ pages: [ComicPage]) async throws -> TranslationController {
        let controller = TranslationController(store: try makeTemporaryTranslationStore(), defaults: InMemoryKeyValueStore(), translator: ScriptedTranslator())
        let analyzer = StubPageAnalyzer(bubbles: 1)
        controller.makeAnalyzer = { _, _ in analyzer }
        controller.requestStart = {}
        controller.reload(pages: pages, pageSizes: [], scope: .strip, source: .japanese, target: .korean, enabled: true, autoStart: false, focusPage: 0)
        await controller.cacheTask?.value
        controller.start()
        try await waitUntil { !controller.isWorking }
        return controller
    }

    /// Read once: a resumed job takes them from here instead of every page's
    /// header. `reload` keeps them only when handed them, so a new book reads
    /// its own.
    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func aJobKeepsThePageSizesItRead() async throws {
        let pages = try stripPages([(20, 30), (40, 50), (20, 60)])
        let controller = try await runStripJob(pages)
        #expect(controller.pageSizes == [CGSize(width: 20, height: 30), CGSize(width: 40, height: 50), CGSize(width: 20, height: 60)])
    }

    /// A page that couldn't be read is tried again by the next job.
    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func unreadablePagesAreNotRemembered() async throws {
        var pages = try stripPages([(20, 30)])
        pages.append(ComicPage(source: .file(URL(fileURLWithPath: "/nonexistent/panely/missing.png")), displayName: "missing"))
        let controller = try await runStripJob(pages)
        #expect(controller.pageSizes.isEmpty)
    }

    // MARK: - Letting go

    /// Keep the model across short reading breaks, with bounded retention
    /// both before its first request and after a job.
    @Test func theModelStaysAvailableAcrossReadingBreaks() async throws {
        #expect(GemmaTranslator.firstRequestTimeout >= GemmaTranslator.idleTimeout)
        #expect(GemmaTranslator.idleTimeout == .seconds(600))
        let missing = TranslationModelFiles(root: try Fixture.makeTempDir())
        let translator = GemmaTranslator(files: missing)
        try? await translator.prepare()
        #expect(await translator.scheduledIdleTimeout == GemmaTranslator.firstRequestTimeout)

        // No model here, so it fails, but it's a request all the same.
        do {
            for try await _ in translator.translate(["一"], context: [], from: .japanese, to: .korean) {}
            Issue.record("translated without a model")
        } catch {}
        #expect(await translator.scheduledIdleTimeout == GemmaTranslator.idleTimeout, "a request ran")
    }

    @Test func cancelledPreparationDoesNotLoadOrRetainAModel() async throws {
        let translator = GemmaTranslator(files: TranslationModelFiles(root: try Fixture.makeTempDir()))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await translator.prepare()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await translator.runtimeLoadCount == 0)
        #expect(await translator.scheduledIdleTimeout == nil)
    }

    @Test(.enabled(if: Bundle.main.url(forResource: "ComicTextDetector", withExtension: "mlmodelc") != nil))
    func theDetectorLetsGoOfItsModelWhenIdle() async throws {
        let image = try #require(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )?.makeImage())
        let detector = BalloonDetector(idleTimeout: .milliseconds(100))
        #expect(await detector.isModelLoaded == false)

        #expect(await detector.detect(image) != nil)
        // Used again within the timeout: it stays.
        #expect(await detector.detect(image) != nil)
        let deadline = ContinuousClock.now + .seconds(10)
        while await detector.isModelLoaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await detector.isModelLoaded == false, "let go after the timeout")

        #expect(await detector.detect(image) != nil, "and comes back when needed")
    }

    @Test func idleBackgroundControllersCanBeDropped() throws {
        let manager = TranslationManager(store: try makeTemporaryTranslationStore(), defaults: InMemoryKeyValueStore())
        let idle = manager.backgroundController(bookKey: "/a", title: "a", bookURL: nil, target: .korean).controller
        let queued = manager.backgroundController(bookKey: "/b", title: "b", bookURL: nil, target: .korean).controller
        queued.reload(pages: Fixture.makeImagePages(count: 1), pageSizes: [], scope: .page, source: .japanese, target: .korean, enabled: true, autoStart: false, focusPage: 0)
        queued.markQueued()
        #expect(manager.background.count == 2)

        manager.dropFinishedBackground()
        #expect(manager.background.count == 1)
        #expect(manager.background.first === queued)
        #expect(manager.background.first !== idle)
    }

    // MARK: - Edits

    /// One directory listing: only pages with a file are opened, and pages'
    /// keys are as they always were, so existing edits are still found.
    @Test func editsAreFoundFromADirectoryListing() throws {
        let store = TranslationEditStore(root: try Fixture.makeTempDir().appendingPathComponent("edits", isDirectory: true))
        #expect(store.loadAll(pageIDs: ["p1"], scope: .page).isEmpty, "no folder yet")

        var edits = PageEdits()
        edits.update(makeTranslatedPage().bubbles[0]) { $0.isHidden = true }
        try store.save(edits, key: TranslationEditStore.key(pageID: "p1", scope: .page))
        try store.save(edits, key: TranslationEditStore.key(pageID: "p3", scope: .strip))
        try store.save(edits, key: TranslationEditStore.key(pageID: "elsewhere", scope: .page))
        try Data("x".utf8).write(to: store.root.appendingPathComponent("notes.txt"))

        #expect(store.loadAll(pageIDs: ["p1", "p2", "p3"], scope: .page) == ["p1": edits])
        #expect(store.existingKeys().count == 3)

        // The hex written by hand, as `String(format:)` gave it.
        let hex = TranslationStore.hex([0x00, 0x0f, 0xa0, 0xff] as [UInt8])
        #expect(hex == "000fa0ff")
    }
}
