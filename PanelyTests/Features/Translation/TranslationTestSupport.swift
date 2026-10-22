import CoreGraphics
import Foundation
import Testing
@testable import Panely

/// Hands out passes one at a time, so a test decides when background work
/// waiting on it moves on.
actor TranslationPermitGate {
    private var permits = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        if isOpen { return }
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release(_ count: Int = 1) {
        for _ in 0..<count {
            if waiters.isEmpty { permits += 1 } else { waiters.removeFirst().resume() }
        }
    }

    /// Let everything through from now on — call at the end so nothing is
    /// left suspended.
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// A stand-in for the model: translates each line as "‹target›:‹line›",
/// one at a time, taking one pass of `gate` (when given) before each — so a
/// test decides when each balloon lands. Records every request.
final class ScriptedTranslator: BalloonTranslating, @unchecked Sendable {
    struct Request: Equatable {
        let lines: [String]
        let context: [TranslationContextLine]
        let source: TranslationLanguage
        let target: TranslationLanguage
    }

    private let ready: @Sendable () -> Bool
    private let gate: TranslationPermitGate?
    /// Lines the model "never answers".
    private let unanswered: Set<String>
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var prepared = 0

    /// `ready`: whether the model is "downloaded" — asked each time.
    init(ready: @escaping @Sendable () -> Bool = { true }, gate: TranslationPermitGate? = nil, unanswered: Set<String> = []) {
        self.ready = ready
        self.gate = gate
        self.unanswered = unanswered
    }

    var requests: [Request] { lock.withLock { recorded } }
    var prepareCount: Int { lock.withLock { prepared } }

    static func translation(of line: String, into target: TranslationLanguage) -> String {
        "\(target.rawValue):\(line)"
    }

    func isReady() -> Bool { ready() }

    func prepare() async throws {
        lock.withLock { prepared += 1 }
    }

    func translate(
        _ lines: [String],
        context: [TranslationContextLine],
        from source: TranslationLanguage,
        to target: TranslationLanguage
    ) -> AsyncThrowingStream<TranslatedLine, any Error> {
        lock.withLock { recorded.append(Request(lines: lines, context: context, source: source, target: target)) }
        let gate = gate
        let unanswered = unanswered
        return AsyncThrowingStream { continuation in
            let task = Task {
                for (index, line) in lines.enumerated() {
                    await gate?.pass()
                    guard !Task.isCancelled else { break }
                    if unanswered.contains(line) { continue }
                    continuation.yield(TranslatedLine(index: index, text: Self.translation(of: line, into: target)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Hands a job balloons instead of reading them off the page: `bubbles`
/// per page, whose originals are `makeTranslationTestPage`'s (so other
/// languages' cached balloons line up), or `texts` when given for the page.
struct StubPageAnalyzer: PageAnalyzing {
    var bubbles = 3
    var texts: [Int: [String]] = [:]

    func analyze(_ unit: TranslationUnit, plan: TranslationPlan) async throws -> [PageAnalysis] {
        unit.pageIndices.map { pageIndex in
            let sources = texts[pageIndex] ?? (0..<bubbles).map { "原文\(pageIndex)-\($0)" }
            return PageAnalysis(
                pageIndex: pageIndex,
                imageSize: CGSize(width: 1000, height: 1500),
                bubbles: sources.enumerated().map { index, source in
                    TranslatedBubble(
                        id: 0,
                        rect: CGRect(x: 100 + Double(index) * 250, y: 200 + Double(index) * 300, width: 120, height: 220),
                        glyphSize: 30,
                        isVertical: true,
                        source: source,
                        translation: nil,
                        background: .white
                    )
                }
            )
        }
    }
}

/// For model stores that never download: tests that reach a download fail it.
struct FailingModelDownloader: TranslationModelDownloading {
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        throw URLError(.notConnectedToInternet)
    }
}

/// Reports `received` of `total`, then waits on `gate` and fails — a
/// download caught mid-way, for pictures of it.
struct StalledModelDownloader: TranslationModelDownloading {
    let received: Int64
    let total: Int64
    let gate: TranslationPermitGate

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        progress(received, total)
        await gate.pass()
        throw CancellationError()
    }
}

/// "Downloads" `data`, reporting progress halfway and at the end, after a
/// pass of `gate` when given.
struct DataModelDownloader: TranslationModelDownloading {
    let data: Data
    var gate: TranslationPermitGate?

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let total = Int64(data.count)
        progress(total / 2, total)
        await gate?.pass()
        try Task.checkCancellation()
        try data.write(to: destination)
        progress(total, total)
    }
}

/// A finished page of `bubbles` balloons whose originals are the same in
/// every language (so the popover's other languages line up), translated as
/// `label`.
func makeTranslationTestPage(pageIndex: Int, bubbles: Int = 3, label: String) -> TranslatedPage {
    TranslatedPage(
        imageWidth: 1000,
        imageHeight: 1500,
        bubbles: (0..<bubbles).map { index in
            TranslatedBubble(
                id: index,
                rect: CGRect(x: 100 + Double(index) * 250, y: 200 + Double(index) * 300, width: 120, height: 220),
                glyphSize: 30,
                isVertical: true,
                source: "原文\(pageIndex)-\(index)",
                // A failed balloon is cached as "".
                translation: index == 2 && label.hasSuffix("!") ? "" : "\(label) \(pageIndex)-\(index)",
                background: .white
            )
        }
    )
}
