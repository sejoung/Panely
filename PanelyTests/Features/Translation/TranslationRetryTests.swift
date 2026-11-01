import Testing
import Foundation
@testable import Panely

/// Reads a page the way the OCR sometimes fails: `failing` holds how many times
/// per page (`Int.max`: every time). `holdFirst` keeps the first read waiting
/// until the test says so.
private final class FlakyAnalyzer: PageAnalyzing, @unchecked Sendable {
    struct OCRFailure: Error {}

    private let lock = NSLock()
    private var failures: [Int: Int]
    private var analyzed: [Int] = []
    private var gate: CheckedContinuation<Void, Never>?
    private let holdFirst: Bool
    private var held = false

    init(failing: [Int: Int] = [:], holdFirst: Bool = false) {
        failures = failing
        self.holdFirst = holdFirst
    }

    var order: [Int] { lock.withLock { analyzed } }
    var isHolding: Bool { lock.withLock { gate != nil } }

    func heal() { lock.withLock { failures = [:] } }

    func release() {
        lock.withLock {
            gate?.resume()
            gate = nil
        }
    }

    func analyze(_ unit: TranslationUnit, plan: TranslationPlan) async throws -> [PageAnalysis] {
        let page = unit.pageIndices[0]
        let shouldFail: Bool = lock.withLock {
            analyzed.append(page)
            guard let count = failures[page], count > 0 else { return false }
            if count != .max { failures[page] = count - 1 }
            return true
        }
        if shouldFail { throw OCRFailure() }
        if holdFirst {
            let hold: Bool = lock.withLock {
                defer { held = true }
                return !held
            }
            if hold {
                await withCheckedContinuation { continuation in
                    lock.withLock { gate = continuation }
                }
            }
        }
        return try await StubPageAnalyzer().analyze(unit, plan: plan)
    }
}

@MainActor
@Suite(.enabled(if: TranslationController.isSupportedOnThisMac))
struct TranslationRetryTests {
    private func makeController(_ analyzer: FlakyAnalyzer, pages: [ComicPage]) async throws -> TranslationController {
        let controller = TranslationController(
            store: try makeTemporaryTranslationStore(),
            defaults: InMemoryKeyValueStore(),
            translator: ScriptedTranslator()
        )
        controller.makeAnalyzer = { _, _ in analyzer }
        controller.requestStart = {}
        controller.reload(
            pages: pages, pageSizes: [], scope: .page, source: .japanese, target: .korean,
            enabled: true, autoStart: false, focusPage: 0
        )
        await controller.cacheTask?.value
        return controller
    }

    /// The OCR failing once mustn't lose a page; it goes round again at the end.
    @Test func aPageThatFailsOnceIsRetriedAfterTheOthers() async throws {
        let pages = Fixture.makeImagePages(count: 4)
        let analyzer = FlakyAnalyzer(failing: [1: 1])
        let controller = try await makeController(analyzer, pages: pages)

        controller.start()
        try await waitUntil { !controller.isWorking }

        #expect(controller.completedPageCount == 4)
        #expect(controller.notice == nil)
        #expect(analyzer.order.last == 1)
        #expect(analyzer.order.filter { $0 == 1 }.count == 2)
        #expect(controller.pages[pages[1].id]?.bubbles.allSatisfy { $0.translation?.isEmpty == false } == true)
    }

    @Test func theLastPageFailingIsRetriedToo() async throws {
        let pages = Fixture.makeImagePages(count: 3)
        let analyzer = FlakyAnalyzer(failing: [2: 1])
        let controller = try await makeController(analyzer, pages: pages)

        controller.start()
        try await waitUntil { !controller.isWorking }

        #expect(controller.completedPageCount == 3)
        #expect(controller.notice == nil)
    }

    /// Finishing "successfully" with a page missing is what hid this before.
    @Test func aPageThatKeepsFailingIsReportedAndLeftToTranslateAgain() async throws {
        let pages = Fixture.makeImagePages(count: 3)
        let analyzer = FlakyAnalyzer(failing: [1: .max])
        let controller = try await makeController(analyzer, pages: pages)

        controller.start()
        try await waitUntil { !controller.isWorking }

        #expect(controller.notice == .pagesFailed(1))
        #expect(controller.completedPageCount == 2)
        #expect(analyzer.order.filter { $0 == 1 }.count == 2, "one retry, not for ever")

        // Translating again does only that page.
        analyzer.heal()
        let before = analyzer.order.count
        controller.start()
        try await waitUntil { !controller.isWorking }

        #expect(controller.notice == nil)
        #expect(controller.completedPageCount == 3)
        #expect(Array(analyzer.order[before...]) == [1])
        #expect(controller.pages[pages[1].id]?.bubbles.allSatisfy { $0.translation?.isEmpty == false } == true)
    }

    /// A job whose every page fails still stops early rather than trying them all.
    @Test func consecutiveFailuresStillStopTheJob() async throws {
        let pages = Fixture.makeImagePages(count: 8)
        let analyzer = FlakyAnalyzer(failing: Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, Int.max) }))
        let controller = try await makeController(analyzer, pages: pages)

        controller.start()
        try await waitUntil { !controller.isWorking }

        guard case .failed = controller.notice else {
            Issue.record("expected the job to give up, got \(String(describing: controller.notice))")
            return
        }
        #expect(analyzer.order.count < 8 + TranslationController.lookahead + 1)
    }

    /// A long OCR wait shows as such, and clears once the page is read.
    @Test func aLongOCRWaitIsShownUntilItEnds() async throws {
        let pages = Fixture.makeImagePages(count: 2)
        let analyzer = FlakyAnalyzer(holdFirst: true)
        let controller = try await makeController(analyzer, pages: pages)
        controller.ocrWaitNoticeDelay = .milliseconds(10)

        controller.start()
        try await waitUntil { analyzer.isHolding && controller.isWaitingForOCR }
        #expect(controller.isWorking)

        analyzer.release()
        try await waitUntil { !controller.isWaitingForOCR }
        try await waitUntil { !controller.isWorking }
        #expect(controller.completedPageCount == 2)
    }
}
