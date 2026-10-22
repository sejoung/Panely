import Foundation
import Testing
@testable import Panely

/// The prompt Gemma gets and how its answer is read (`GemmaPrompt`) — the
/// same as the Windows version's, so both translate a book alike.
struct GemmaPromptTests {
    @Test func promptIsGemmasTurnFormatWithRulesContextAndNumberedLines() {
        let prompt = GemmaPrompt.build(
            lines: ["遅いぞ！", "すみません、\n電車が…"],
            context: [TranslationContextLine(source: "おい、田中！", translation: "야, 다나카!")],
            from: .japanese,
            to: .korean
        )
        #expect(prompt == """
        <|turn>user
        You translate Japanese comic dialogue into natural Korean.
        Rules:
        - Translate every numbered line. Output exactly one line per input line, as "[n] translation", nothing else.
        - Keep each speaker's speech level: polite speech stays polite, plain or casual speech stays casual. In Korean, polite speech is 존댓말 (-요/-습니다) and casual speech is 반말.
        - Keep names, honorifics and terms consistent with the earlier lines.
        - " / " inside a line marks a line break in the balloon; keep it.
        - Do not add explanations.

        Earlier lines (Japanese → Korean), for context only:
        おい、田中！ → 야, 다나카!

        Translate:
        [1] 遅いぞ！
        [2] すみません、 / 電車が…
        <turn|>
        <|turn>model

        """)
    }

    @Test func speechLevelHintFollowsTheTargetAndContextIsLeftOutWhenEmpty() {
        let japanese = GemmaPrompt.build(lines: ["야"], context: [], from: .korean, to: .japanese)
        #expect(japanese.contains(" In Japanese, polite speech uses です/ます.\n"))
        #expect(!japanese.contains("Earlier lines"))
        #expect(japanese.hasPrefix("<|turn>user\nYou translate Korean comic dialogue into natural Japanese.\n"))

        let english = GemmaPrompt.build(lines: ["你好"], context: [], from: .chineseTraditional, to: .english)
        #expect(english.contains("plain or casual speech stays casual.\n- Keep names"))
        #expect(english.contains("You translate Traditional Chinese comic dialogue into natural English."))
    }

    @Test func answerLinesAreReadAndEverythingElseIgnored() {
        let output = """
        Sure! Here you go:
        [1] 야, 늦었잖아!
          [2]   죄송합니다, / 전철이 늦어서…\t
        [x] not a line
        [3]
        [12] 열두 번째
        4] broken
        """
        let lines = GemmaPrompt.parse(output)
        #expect(lines.map(\.number) == [1, 2, 12])
        #expect(lines.map(\.text) == ["야, 늦었잖아!", "죄송합니다, / 전철이 늦어서…", "열두 번째"])
    }

    /// Lines are handed on as the model writes them: each one once, as soon
    /// as its newline arrives, never cut short.
    @Test func lineReaderReturnsEachLineOnceItIsComplete() {
        let output = "[1] 야, 다나카!\n[2] 죄송합니다\n[3] 마지막"
        var reader = GemmaPrompt.LineReader()
        var seen: [Int] = []
        var texts: [String] = []
        // Grow the output a character at a time, like tokens arriving.
        for end in output.indices {
            for line in reader.read(String(output[...end])) {
                seen.append(line.number)
                texts.append(line.text)
            }
        }
        #expect(seen == [1, 2])
        #expect(texts == ["야, 다나카!", "죄송합니다"])
        // The last line once the output ends.
        #expect(reader.read(output + "\n").map(\.text) == ["마지막"])
        #expect(reader.read(output + "\n").isEmpty)
    }

    @Test func cleaningRestoresLineBreaksAndTurnsMangaDashesIntoDashes() {
        #expect(GemmaPrompt.clean("변명은 됐어. / 어서 앉아.", target: .korean) == "변명은 됐어.\n어서 앉아.")
        #expect(GemmaPrompt.clean("ーーー잠깐만!", target: .korean) == "———잠깐만!")
        #expect(GemmaPrompt.clean("ちょっとーー待って", target: .japanese) == "ちょっとーー待って")
        // A single long-vowel mark is a word's own.
        #expect(GemmaPrompt.clean("ラーメン", target: .english) == "ラーメン")
    }

    @Test func balloonTextGoesOnOneLine() {
        #expect(GemmaPrompt.oneLine("  一行目\r\n二行目\n三行目 \n") == "一行目 / 二行目 / 三行目")
    }

    @Test func roomToAnswerGrowsWithTheLines() {
        #expect(GemmaPrompt.maxTokens([]) == 64)
        #expect(GemmaPrompt.maxTokens(["ab", "あいう"]) == 64 + (16 + 6) + (16 + 9))
    }
}
