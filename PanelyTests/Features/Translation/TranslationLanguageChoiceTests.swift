import Testing
import Foundation
@testable import Panely

@Suite(.enabled(if: TranslationController.isSupportedOnThisMac))
struct TranslationLanguageDetectionTests {
    /// Real OCR of a Korean edition's first pages: the cover's English title
    /// must not settle it before the first page of Korean is read.
    @Test func anEnglishTitleOnACoverDoesNotDecideTheBook() throws {
        guard #available(macOS 26.0, *) else { return }
        let cover = "ロフ」 The labyrinth of magic OHTAKA Shinobu"
        #expect(TranslationLanguageClassifier.classify(cover) == .english)
        #expect(!TranslationLanguageDetector.isConclusive(cover))

        let withContents = cover + " The labyrinth of magic MAGI CONTENTS 1번째 밤 그 이름은 알라딘 2번째 밤 그 이름은"
        #expect(TranslationLanguageDetector.isConclusive(withContents))
        #expect(TranslationLanguageClassifier.classify(withContents) == .korean)
    }

    @Test func tooLittleTextDoesNotDecide() {
        guard #available(macOS 26.0, *) else { return }
        #expect(!TranslationLanguageDetector.isConclusive("안녕"))
        #expect(TranslationLanguageDetector.isConclusive("안녕하세요 오늘 날씨가 좋네요"))
    }
}

@MainActor
struct TranslationLanguageChoiceTests {
    private func makeFailedDetection(in root: URL) async throws -> TranslationController {
        let store = TranslationStore(root: root.appendingPathComponent("cache", isDirectory: true))
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore(), translator: UnavailableTranslator())
        let bad = root.appendingPathComponent("bad.jpg")
        try Data("not an image".utf8).write(to: bad)
        controller.reload(
            pages: [ComicPage(source: .file(bad), displayName: "bad.jpg")],
            pageSizes: [], scope: .page, source: nil, target: .english,
            enabled: true, autoStart: false, focusPage: 0
        )
        controller.start()
        try await waitUntil { controller.notice == .couldNotDetectLanguage }
        return controller
    }

    /// The notice says to choose the language; choosing it has to do something.
    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func choosingALanguageAfterAFailedDetectionStartsTheJob() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try await makeFailedDetection(in: root)

        controller.setSource(.korean)

        #expect(controller.source == .korean)
        // Started: it now gets as far as asking for the model.
        try await waitUntil { controller.notice == .needsModelDownload }
    }

    @Test func choosingALanguageOnAnIdleBookDoesNotStartAJob() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranslationStore(root: root.appendingPathComponent("cache", isDirectory: true))
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore(), translator: UnavailableTranslator())
        controller.reload(
            pages: Fixture.makeImagePages(count: 1), pageSizes: [], scope: .page, source: nil, target: .english,
            enabled: true, autoStart: false, focusPage: 0
        )

        controller.setSource(.korean)

        try await Task.sleep(for: .milliseconds(30))
        #expect(!controller.isWorking)
        #expect(controller.notice == nil)
    }

    private struct UnavailableTranslator: BalloonTranslating {
        func isReady() -> Bool { false }
        func prepare() async throws {}
        func translate(
            _ lines: [String],
            context: [TranslationContextLine],
            from source: TranslationLanguage,
            to target: TranslationLanguage
        ) -> AsyncThrowingStream<TranslatedLine, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }
}

@MainActor
struct TranslationWarmupTriggerTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func makeViewModel(
        enabled: Bool,
        warmedBuild: String? = nil,
        counter: Counter
    ) -> (ReaderViewModel, InMemoryKeyValueStore) {
        let store = InMemoryKeyValueStore()
        store.set(enabled, forKey: ReaderPreferences.translationEnabledKey)
        if let warmedBuild { store.set(warmedBuild, forKey: TranslationController.warmedUpBuildKey) }
        var dependencies = makeTestDependencies(keyValueStore: store)
        dependencies.warmUpTranslation = { counter.increment() }
        return (ReaderViewModel(dependencies: dependencies), store)
    }

    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func runsOncePerBuildAndRemembersIt() async throws {
        let counter = Counter()
        let (vm, store) = makeViewModel(enabled: true, counter: counter)
        try await waitUntil {
            store.dictionaryRepresentation()[TranslationController.warmedUpBuildKey] as? String == TranslationController.buildIdentifier
        }
        vm.reloadTranslations()
        #expect(counter.count == 1)
    }

    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func skippedWhenThisBuildIsAlreadyWarm() async throws {
        let counter = Counter()
        let (vm, _) = makeViewModel(enabled: true, warmedBuild: TranslationController.buildIdentifier, counter: counter)
        vm.reloadTranslations()
        try await Task.sleep(for: .milliseconds(30))
        #expect(counter.count == 0)
    }

    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func anUpdateWarmsUpAgain() async throws {
        let counter = Counter()
        _ = makeViewModel(enabled: true, warmedBuild: "older-build", counter: counter)
        try await waitUntil { counter.count == 1 }
    }

    /// People who never turned translation on shouldn't pay a minute of CPU.
    @Test func waitsForTranslationToBeTurnedOn() async throws {
        let counter = Counter()
        let (vm, _) = makeViewModel(enabled: false, counter: counter)
        vm.reloadTranslations()
        try await Task.sleep(for: .milliseconds(30))
        #expect(counter.count == 0)
    }
}
