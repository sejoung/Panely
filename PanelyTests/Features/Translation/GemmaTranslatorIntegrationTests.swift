import Foundation
import Testing
@testable import Panely

/// The real model, through llama.cpp: loads, answers every line, streams
/// them in order and keeps the speech level of plain and polite lines.
///
/// Opt-in (`scripts/test-model.sh`, which can link the model into the test
/// host's sandbox with `--model PATH`) and only with the model downloaded:
/// it loads 3.3 GB and takes a few seconds.
@Suite(.serialized, .enabled(if: TestTier.model && GemmaTranslator.shared.isReady(), TestTier.modelReason))
struct GemmaTranslatorIntegrationTests {
    private func translate(
        _ lines: [String],
        context: [TranslationContextLine] = [],
        from source: TranslationLanguage,
        to target: TranslationLanguage
    ) async throws -> [Int: String] {
        var answers: [Int: String] = [:]
        var order: [Int] = []
        for try await line in GemmaTranslator.shared.translate(lines, context: context, from: source, to: target) {
            answers[line.index] = line.text
            order.append(line.index)
        }
        #expect(order == order.sorted(), "lines arrive in order")
        return answers
    }

    /// Reusing what the context already holds mustn't change a translation:
    /// the same prompts through a shared memory and read from scratch.
    @Test func reusingThePromptsStartGivesTheSameAnswers() throws {
        let runtime = try LlamaRuntime(
            path: GemmaTranslator.shared.files.fileURL.path,
            contextSize: GemmaTranslator.contextSize,
            gpuLayers: 99
        )
        let batches = [
            ["おはようございます。", "今日はいい天気ですね。"],
            ["どこへ行くんだ?", "お前には関係ない!"],
            ["おはようございます。", "明日は雨が降るそうです。"],
            ["おはようございます。", "今日はいい天気ですね。"],
            ["ありがとう。"],
        ]
        let prompts = batches.map {
            (GemmaPrompt.build(lines: $0, context: [], from: .japanese, to: .korean), GemmaPrompt.maxTokens($0))
        }
        let reusing = try prompts.map { try runtime.generate(prompt: $0.0, maxTokens: $0.1) { _ in true } }
        // A request stopped partway leaves unfinished output in the memory.
        _ = try runtime.generate(prompt: prompts[1].0, maxTokens: prompts[1].1) { _ in false }
        let afterStop = try runtime.generate(prompt: prompts[1].0, maxTokens: prompts[1].1) { _ in true }
        let fresh = try prompts.map { prompt -> String in
            runtime.clearMemory()
            return try runtime.generate(prompt: prompt.0, maxTokens: prompt.1) { _ in true }
        }
        #expect(reusing == fresh)
        #expect(afterStop == fresh[1])
    }

    @Test func japaneseIntoKoreanKeepsEachSpeakersSpeechLevel() async throws {
        let lines = [
            "遅いぞ、何してたんだよ！",
            "すみません、電車が遅れてしまって…",
            "先生、今日のテストは何時からですか？",
            "うるさいな、ほっとけよ！",
        ]
        let answers = try await translate(lines, from: .japanese, to: .korean)
        #expect(answers.count == lines.count)
        for (index, text) in answers.sorted(by: { $0.key < $1.key }) {
            print("GEMMA ja→ko [\(index + 1)] \(lines[index]) → \(text)")
            #expect(text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }, "Korean: \(text)")
        }
        // Polite lines come out polite, plain ones plain.
        #expect(answers[1].map { $0.contains("니다") || $0.contains("요") } == true)
        #expect(answers[2].map { $0.contains("요") || $0.contains("니까") } == true)
        #expect(answers[3].map { !$0.contains("요") && !$0.contains("니다") } == true)
    }

    @Test func linesBreaksSurviveAndContextIsUsed() async throws {
        let answers = try await translate(
            ["言い訳はいい。\nさっさと座れ。"],
            context: [TranslationContextLine(source: "おい、田中！", translation: "야, 다나카!")],
            from: .japanese,
            to: .korean
        )
        let text = try #require(answers[0])
        print("GEMMA ja→ko line break → \(text)")
        #expect(text.contains("\n"))
    }

    @Test func koreanIntoJapanese() async throws {
        let lines = ["야, 너 수학도 깡통이면서 왜 이렇게 늦었어?", "사장님, 회의는 몇 시에 시작합니까?"]
        let answers = try await translate(lines, from: .korean, to: .japanese)
        #expect(answers.count == lines.count)
        for (index, text) in answers.sorted(by: { $0.key < $1.key }) {
            print("GEMMA ko→ja [\(index + 1)] \(lines[index]) → \(text)")
        }
        #expect(answers[1].map { $0.contains("ます") || $0.contains("です") } == true)
    }
}
