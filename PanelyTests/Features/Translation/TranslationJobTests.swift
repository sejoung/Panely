import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Panely

/// How a job hands balloons to the model: a unit's new lines together, at
/// most `chunkSize` at a time, with the job's last `contextLines`
/// translations as context; lines seen before reused; lines the model never
/// answers left untranslated; no model, no job.
@MainActor
@Suite(.enabled(if: TranslationController.isSupportedOnThisMac))
struct TranslationJobTests {
    private func makeController(
        _ translator: ScriptedTranslator,
        texts: [Int: [String]],
        store: TranslationStore? = nil
    ) throws -> TranslationController {
        let controller = TranslationController(
            store: try store ?? makeTemporaryTranslationStore(),
            defaults: InMemoryKeyValueStore(),
            translator: translator
        )
        let analyzer = StubPageAnalyzer(texts: texts)
        controller.makeAnalyzer = { _, _ in analyzer }
        controller.requestStart = {}
        return controller
    }

    private func run(_ controller: TranslationController, pages: [ComicPage]) async throws {
        controller.reload(
            pages: pages, pageSizes: [], scope: .page, source: .japanese, target: .korean,
            enabled: true, autoStart: false, focusPage: 0
        )
        await controller.cacheTask?.value
        controller.start()
        try await waitUntil { !controller.isWorking }
    }

    private func translations(_ controller: TranslationController, _ page: ComicPage) -> [String?] {
        (controller.pages[page.id]?.bubbles ?? []).sorted { $0.rect.minY < $1.rect.minY }.map(\.translation)
    }

    @Test func balloonsGoInChunksWithTheLastTranslationsAsContext() async throws {
        let first = (0..<10).map { "一\($0)" }
        let second = ["一0"] + (0..<10).map { "二\($0)" }
        let third = (0..<20).map { "三\($0)" }
        let translator = ScriptedTranslator()
        let controller = try makeController(translator, texts: [0: first, 1: second, 2: third])
        let pages = Fixture.makeImagePages(count: 3)

        try await run(controller, pages: pages)
        #expect(controller.notice == nil)
        #expect(controller.completedPageIndices == [0, 1, 2])
        #expect(translator.prepareCount == 1)

        func context(_ lines: ArraySlice<String>) -> [TranslationContextLine] {
            lines.map { TranslationContextLine(source: $0, translation: ScriptedTranslator.translation(of: $0, into: .korean)) }
        }
        let requests = translator.requests
        #expect(requests.map(\.lines) == [
            first,
            // "一0" again: reused, not asked for.
            Array(second.dropFirst()),
            Array(third.prefix(16)),
            Array(third.suffix(4)),
        ])
        #expect(requests.map(\.context) == [
            [],
            context(first.suffix(6)),
            context(second.suffix(6)),
            context(third[10..<16]),
        ])
        #expect(requests.allSatisfy { $0.source == .japanese && $0.target == .korean })

        #expect(translations(controller, pages[1]) == second.map { ScriptedTranslator.translation(of: $0, into: .korean) })
        // Finished pages are cached under the model's revision.
        let saved = controller.store.load(key: TranslationStore.key(pageID: pages[2].id, from: .japanese, to: .korean))
        #expect(saved?.isComplete == true)
        #expect(saved?.bubbles.count == 20)
    }

    @Test func aRepeatedLineOnOnePageIsAskedForOnce() async throws {
        let translator = ScriptedTranslator()
        let controller = try makeController(translator, texts: [0: ["はい", "いいえ", "はい"]])
        let pages = Fixture.makeImagePages(count: 1)

        try await run(controller, pages: pages)
        #expect(translator.requests.map(\.lines) == [["はい", "いいえ"]])
        #expect(translations(controller, pages[0]) == ["ko:はい", "ko:いいえ", "ko:はい"])
    }

    /// A line the model skips (even asked again on its own) shows as a
    /// balloon that couldn't be translated, and is asked for again when it
    /// comes up later — not reused.
    @Test func aLineTheModelNeverAnswersIsLeftUntranslatedAndAskedForAgain() async throws {
        let translator = ScriptedTranslator(unanswered: ["二"])
        let controller = try makeController(translator, texts: [0: ["一", "二"], 1: ["二", "三"]])
        let pages = Fixture.makeImagePages(count: 2)

        try await run(controller, pages: pages)
        #expect(controller.notice == nil)
        #expect(translations(controller, pages[0]) == ["ko:一", ""])
        #expect(translations(controller, pages[1]) == ["", "ko:三"])
        #expect(translator.requests.map(\.lines) == [["一", "二"], ["二", "三"]])
        // Unanswered lines aren't context.
        #expect(translator.requests[1].context == [TranslationContextLine(source: "一", translation: "ko:一")])
        #expect(controller.completedPageIndices == [0, 1])
    }

    /// Each balloon shows the moment its line comes back, not when the
    /// whole request is done.
    @Test func balloonsShowAsTheirLinesArrive() async throws {
        let gate = TranslationPermitGate()
        let translator = ScriptedTranslator(gate: gate)
        let controller = try makeController(translator, texts: [0: ["一", "二", "三"]])
        let pages = Fixture.makeImagePages(count: 1)
        controller.reload(pages: pages, pageSizes: [], scope: .page, source: .japanese, target: .korean, enabled: true, autoStart: false, focusPage: 0)
        await controller.cacheTask?.value

        controller.start()
        try await waitUntil { translations(controller, pages[0]).count == 3 }
        #expect(translations(controller, pages[0]) == [nil, nil, nil])
        await gate.release()
        try await waitUntil { translations(controller, pages[0]) == ["ko:一", nil, nil] }
        await gate.release()
        try await waitUntil { translations(controller, pages[0]) == ["ko:一", "ko:二", nil] }
        #expect(controller.isWorking)
        await gate.release()
        try await waitUntil { !controller.isWorking }
        #expect(controller.completedPageIndices == [0])
    }

    @Test func withoutTheModelTheJobAsksForTheDownload() async throws {
        let translator = ScriptedTranslator(ready: { false })
        let controller = try makeController(translator, texts: [0: ["一"]])

        try await run(controller, pages: Fixture.makeImagePages(count: 1))
        #expect(controller.notice == .needsModelDownload)
        #expect(controller.phase == .idle)
        #expect(translator.requests.isEmpty)
        #expect(translator.prepareCount == 0)
    }

    /// Jobs that stopped for want of the model start again once it's
    /// downloaded — here a book open in the reader.
    @Test func downloadingTheModelRestartsTheJobsWaitingForIt() async throws {
        let content = Data("model".utf8)
        let model = TranslationModel(
            id: "test-model", displayName: "Test", revision: "r", fileName: "m.gguf", bytes: Int64(content.count),
            sha256: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://example.invalid/m.gguf")!, license: "Apache-2.0"
        )
        let pinnedFiles = TranslationModelFiles(root: try Fixture.makeTempDir(), model: model)
        let modelStore = TranslationModelStore(files: pinnedFiles, downloader: DataModelDownloader(data: content))
        let translator = ScriptedTranslator(ready: { pinnedFiles.isInstalled })
        let manager = TranslationManager(
            store: try makeTemporaryTranslationStore(),
            defaults: InMemoryKeyValueStore(),
            translator: translator,
            model: modelStore,
            makeAnalyzer: { _, _ in StubPageAnalyzer(bubbles: 2) }
        )
        let pages = Fixture.makeImagePages(count: 2)
        manager.beginBook(key: "/book.cbz", title: "Book", url: nil)
        let (controller, _) = manager.controller(for: .korean)
        controller.reload(pages: pages, pageSizes: [], scope: .page, source: .japanese, target: .korean, enabled: true, autoStart: false, focusPage: 0)
        await controller.cacheTask?.value

        manager.start(controller)
        try await waitUntil { controller.notice == .needsModelDownload }
        #expect(translator.requests.isEmpty)

        modelStore.download()
        try await waitUntil { controller.completedPageIndices == [0, 1] }
        #expect(controller.notice == nil)
        #expect(translator.requests.count == 2)
    }
}
