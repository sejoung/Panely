import Foundation
import Testing
@testable import Panely

/// Reading Japanese and Korean speech levels, and deciding whether a rewrite
/// may replace a translation. The model itself isn't run here.
struct SpeechLevelRulesTests {
    @Test func japaneseLevelsComeFromTheLineItself() {
        #expect(SpeechLevelRules.level(ofSource: "アッシャー卿がお待ちでございます", language: .japanese) == .polite)
        #expect(SpeechLevelRules.level(ofSource: "お願いですから言葉をお選びください…！！", language: .japanese) == .polite)
        #expect(SpeechLevelRules.level(ofSource: "我の声が聞こえるかー", language: .japanese) == .plain)
        #expect(SpeechLevelRules.level(ofSource: "…言動には気をつけなさいロミナ", language: .japanese) == .plain)
        // Narration and pronouncements.
        #expect(SpeechLevelRules.level(ofSource: "その結果カラムチャンドは大義なき侵略戦争に踏み切った", language: .japanese) == .plainWritten)
        #expect(SpeechLevelRules.level(ofSource: "とにかくこれはお前に与えた任務だ", language: .japanese) == .plainWritten)
        // Nothing to go on.
        #expect(SpeechLevelRules.level(ofSource: "教皇庁", language: .japanese) == nil)
    }

    @Test func koreanLevelsComeFromTheLastEnding() {
        #expect(SpeechLevelRules.level(ofTranslation: "어쨌든 이것은 당신에게 주어진 임무입니다.", language: .korean) == .polite)
        #expect(SpeechLevelRules.level(ofTranslation: "내 목소리가 들리나요?", language: .korean) == .polite)
        #expect(SpeechLevelRules.level(ofTranslation: "그것이 교황에게 명령하는 일입니까!?", language: .korean) == .polite)
        #expect(SpeechLevelRules.level(ofTranslation: "갑시다", language: .korean) == .polite)
        #expect(SpeechLevelRules.level(ofTranslation: "다~카~니까!", language: .korean) == .plain)
        #expect(SpeechLevelRules.level(ofTranslation: "잠이 안 와…", language: .korean) == .plain)
        #expect(SpeechLevelRules.level(ofTranslation: "그 결과 대의 없는 침략 전쟁에 뛰어들었다.", language: .korean) == .plainWritten)
        #expect(SpeechLevelRules.level(ofTranslation: "...", language: .korean) == nil)
    }

    @Test func onlyJapaneseAndKoreanPairs() {
        #expect(SpeechLevelRules.supports(from: .japanese, to: .korean))
        #expect(SpeechLevelRules.supports(from: .korean, to: .japanese))
        #expect(!SpeechLevelRules.supports(from: .japanese, to: .english))
        #expect(!SpeechLevelRules.supports(from: .chineseSimplified, to: .korean))
    }

    @Test func aRewriteIsUsedOnlyIfItChecksOut() {
        let draft = "어쨌든 이것은 당신에게 주어진 임무입니다."
        func accepts(_ rewrite: String) -> Bool {
            SpeechLevelRules.accepts(rewrite, replacing: draft, language: .korean, level: .plain)
        }
        #expect(accepts("어쨌든 이것은 너에게 주어진 임무야."))
        // Still polite.
        #expect(!accepts("어쨌든 이것은 너에게 주어진 임무예요."))
        // Answered in the wrong language.
        #expect(!accepts("とにかくこれはお前に与えた任務だ"))
        // Said something else.
        #expect(!accepts("신경 쓰지 마."))
        // Ran on.
        #expect(!accepts("어쨌든 이것은 너에게 주어진 임무야. 그러니 반드시 끝까지 해내고 돌아와야 한다."))
        #expect(!accepts(draft))
    }

    @Test func japaneseRewritesAreCheckedTheSameWay() {
        let draft = "知らない人はついて行ってはいけません。"
        #expect(SpeechLevelRules.accepts("知らない人について行っちゃだめだ。", replacing: draft, language: .japanese, level: .plain))
        #expect(!SpeechLevelRules.accepts("모르는 사람은 따라가면 안 돼", replacing: draft, language: .japanese, level: .plain))
    }

    /// Real rewrites the model made that changed more than the level —
    /// each must be turned down.
    @Test func rewritesThatChangeTheMeaningAreTurnedDown() {
        func korean(_ rewrite: String, _ draft: String) -> Bool {
            SpeechLevelRules.accepts(rewrite, replacing: draft, language: .korean, level: .plain)
        }
        func japanese(_ rewrite: String, _ draft: String) -> Bool {
            SpeechLevelRules.accepts(rewrite, replacing: draft, language: .japanese, level: .plain)
        }
        // "저 녀석" is "that guy", not "me".
        #expect(!korean("아, 난 녀석? 그것은 지연 사정이야!", "아, 저 녀석? 그것은 지연 사정입니다!"))
        // A request isn't an intention or a remark.
        #expect(!korean("총 6명을 이 라스하르드에 모으겠어", "총 6명을 이 라스하르드에 모으세요"))
        #expect(!korean("좋아하는 것을 선택하고 즐기네.", "좋아하는 것을 선택하고 즐기세요"))
        #expect(korean("좋아하는 것을 선택하고 즐겨.", "좋아하는 것을 선택하고 즐기세요"))
        // A question stays one.
        #expect(!japanese("クちゃんはずっとそこに置かれていると思うよ。", "それでは、クちゃんはずっとそこに置かれているのでしょうか？"))
        // "Probably", tense, negation, "because", requests, passives.
        #expect(!japanese("それは彼女である。", "それは彼女でしょう。"))
        #expect(japanese("それは彼女だろう。", "それは彼女でしょう。"))
        #expect(!japanese("善良な子どもとして生きることが、突然虚しくなる。", "善良な子どもとして生きることが、突然虚しくなったのです。"))
        #expect(!japanese("誰もいれば、空き家だよ。", "誰もいなければ、空き家です。"))
        #expect(!japanese("大人はみんなそう言うのは明らかだよね。", "大人は皆そう言うのは明らかですから。"))
        #expect(!japanese("いつも正しく行動してるよ", "いつも正しく行動してくださいね"))
        #expect(japanese("気をつけて行ってね", "気をつけて行ってください"))
        #expect(!japanese("概ね、拒否すべきだと考えられる。", "概ね、拒否すべきだと考えます。"))
    }

    @Test func onlyPoliteTranslationsOfPlainOriginalsAreRewritten() {
        #expect(SpeechLevelRules.needsRewrite(translation: .polite, original: .plain))
        #expect(SpeechLevelRules.needsRewrite(translation: .polite, original: .plainWritten))
        #expect(!SpeechLevelRules.needsRewrite(translation: .plain, original: .polite))
        #expect(!SpeechLevelRules.needsRewrite(translation: .plain, original: .plainWritten))
    }

    @Test func answersLoseTheirWrapping() {
        #expect(SpeechLevelRules.cleaned("  “내 목소리가 들리니?”\n") == "내 목소리가 들리니?")
        #expect(SpeechLevelRules.cleaned("「だめだ」") == "だめだ")
        #expect(SpeechLevelRules.cleaned("잠이 안 와.\n(어미만 바꿨습니다)") == "잠이 안 와.")
    }
}

/// A stand-in for the on-device model: rewrites the lines it knows.
private struct FakeCorrector: SpeechLevelCorrecting {
    let rewrites: [String: String]
    func correct(_ translation: String, source: String) async -> String? {
        rewrites[translation]
    }
}

@MainActor
struct TranslationControllerSpeechLevelTests {
    private func makeController(
        store: TranslationStore,
        rewrites: [String: String] = ["번역": "고친 번역"]
    ) -> TranslationController {
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore())
        controller.makeSpeechLevelCorrector = { source, target in
            SpeechLevelRules.supports(from: source, to: target) ? FakeCorrector(rewrites: rewrites) : nil
        }
        return controller
    }

    private func reload(_ controller: TranslationController, pages: [ComicPage], match: Bool) {
        controller.reload(
            pages: pages, pageSizes: [], scope: .page, source: .japanese, target: .korean,
            matchSpeechLevel: match, enabled: true, autoStart: false, focusPage: 0
        )
    }

    @Test func cachedPagesAreMatchedOnceAndSavedBack() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 2)
        let key = TranslationStore.key(pageID: pages[0].id, from: .japanese, to: .korean)
        try store.save(makeTranslatedPage("번역"), key: key)
        var alreadyChecked = makeTranslatedPage("번역")
        alreadyChecked.speechLevelChecked = true
        try store.save(alreadyChecked, key: TranslationStore.key(pageID: pages[1].id, from: .japanese, to: .korean))
        let controller = makeController(store: store)

        reload(controller, pages: pages, match: true)
        try await waitUntil { controller.pages[pages[0].id]?.speechLevelChecked == true && controller.speechLevelProgress == nil }

        #expect(controller.pages[pages[0].id]?.bubbles.first?.translation == "고친 번역")
        // Matched before: left as it was.
        #expect(controller.pages[pages[1].id]?.bubbles.first?.translation == "번역")
        // Saved under the entry it came from, so it isn't done again.
        try await waitUntil { store.load(key: key)?.speechLevelChecked == true }
        #expect(store.load(key: key)?.bubbles.first?.translation == "고친 번역")
    }

    @Test func offOrAnotherPairLeavesTranslationsAlone() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 1)
        try store.save(makeTranslatedPage("번역"), key: TranslationStore.key(pageID: pages[0].id, from: .japanese, to: .korean))
        let controller = makeController(store: store)

        reload(controller, pages: pages, match: false)
        await controller.cacheTask?.value

        #expect(controller.speechLevelProgress == nil)
        #expect(controller.pages[pages[0].id]?.bubbles.first?.translation == "번역")
        #expect(controller.pages[pages[0].id]?.speechLevelChecked == nil)
    }
}
