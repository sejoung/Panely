import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Matches a translation's speech level to the original's.
///
/// Apple Translation translates one balloon at a time and leans polite
/// whatever the original says: a god's plain "これはお前に与えた任務だ" comes out
/// "…주어진 임무입니다", a plain "안 돼." comes out "だめです" (measured on
/// real books: 45% of plain Korean balloons came back as です/ます Japanese).
/// Japanese and Korean both mark politeness in the sentence itself, so the
/// original's level can be read off it reliably — no model needed.
///
/// Only the rewrite needs a model: the on-device one (Apple Intelligence) is
/// asked to change the endings and nothing else, and the result is kept only
/// if it checks out (right script, the same words, the wanted level).
/// Otherwise the translation stays as it was, so this can't make a balloon
/// worse. Asking the same model to "improve the page with context" was tried
/// and rejected: it answered in the wrong language, softened or dropped words
/// and made things up.
nonisolated enum SpeechLevel: Equatable, Sendable {
    case polite
    case plain
    /// Plain written style — narration, pronouncements ("…했다", "…である").
    case plainWritten

    var isPlain: Bool { self != .polite }
}

nonisolated enum SpeechLevelRules {
    /// Pairs where both sides mark speech level in the sentence.
    static func supports(from source: TranslationLanguage, to target: TranslationLanguage) -> Bool {
        (source == .japanese && target == .korean) || (source == .korean && target == .japanese)
    }

    // MARK: - Reading the level

    /// The level the original speaks in.
    static func level(ofSource text: String, language: TranslationLanguage) -> SpeechLevel? {
        switch language {
        case .japanese: japaneseLevel(text)
        case .korean: koreanLevel(text)
        default: nil
        }
    }

    /// The level a translation came out in. Plain and plain-written count as
    /// the same here — only polite vs plain is corrected.
    static func level(ofTranslation text: String, language: TranslationLanguage) -> SpeechLevel? {
        switch language {
        case .japanese: japaneseLevel(text)
        case .korean: koreanLevel(text)
        default: nil
        }
    }

    private static let japanesePoliteMarkers = [
        "です", "ます", "ました", "ません", "ましょう", "ませ", "でした", "でしょう",
        "ございま", "ください", "下さい", "いたし", "おりま", "存じ",
    ]

    /// Polite as soon as any polite form appears. Plain-written when it ends
    /// like narration — a bare た/だ/である with no particle after it.
    private static func japaneseLevel(_ text: String) -> SpeechLevel? {
        guard text.unicodeScalars.contains(where: isKana) else { return nil }
        if japanesePoliteMarkers.contains(where: text.contains) { return .polite }
        let end = trimmedEnd(text)
        if end.hasSuffix("である") || end.hasSuffix("のだ") || end.hasSuffix("た") || end.hasSuffix("だ") {
            return .plainWritten
        }
        return .plain
    }

    /// From the last sentence's ending.
    private static func koreanLevel(_ text: String) -> SpeechLevel? {
        let end = trimmedEnd(text)
        guard let last = end.unicodeScalars.last, isHangulSyllable(last) else { return nil }
        if ["요", "죠", "니다", "시오", "시다"].contains(where: end.hasSuffix) { return .polite }
        // "갑니까" is polite; "그러니까" is not — the syllable before has ㅂ.
        if end.hasSuffix("니까"), let before = end.dropLast(2).unicodeScalars.last, isHangulSyllable(before),
           (before.value - 0xAC00) % 28 == 17 {
            return .polite
        }
        return end.hasSuffix("다") ? .plainWritten : .plain
    }

    private static func trimmedEnd(_ text: String) -> String {
        let trailing = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
            .union(CharacterSet(charactersIn: "…~〜ー―—・"))
        var end = text
        while let last = end.unicodeScalars.last, trailing.contains(last) {
            end.unicodeScalars.removeLast()
        }
        return end
    }

    /// Only a polite translation of a plain original is rewritten — Apple
    /// Translation's lean. The other way round is rare, and rewriting it made
    /// fixed phrases odd ("さようならです").
    static func needsRewrite(translation have: SpeechLevel, original wanted: SpeechLevel) -> Bool {
        have == .polite && wanted.isPlain
    }

    // MARK: - Asking for a rewrite

    /// What the model is told to do: change the endings to `level` and
    /// nothing else.
    static func instructions(for language: TranslationLanguage, level: SpeechLevel) -> String {
        switch (language, level) {
        case (.korean, .polite):
            "다음 한국어 문장을 존댓말(해요체나 합쇼체)로 바꿔라. " + koreanRules
        case (.korean, .plainWritten):
            "다음 한국어 문장을 해라체(-다)로 바꿔라. " + koreanRules
        case (.korean, _):
            "다음 한국어 문장을 반말(해체)로 바꿔라. " + koreanRules
        case (_, .polite):
            "次の日本語の文を、です・ます調の丁寧体に書き換えてください。" + japaneseRules
        case (_, .plainWritten):
            "次の日本語の文を、だ調の常体（である調は使わない）に書き換えてください。" + japaneseRules
        case (_, .plain):
            "次の日本語の文を、です・ます調を使わない話し言葉（タメ口）に書き換えてください。" + japaneseRules
        }
    }

    private static let koreanRules = "문장 끝 어미와 1·2인칭 대명사(저는→나는, 제가→내가, 당신→너)만 바꾸고 나머지 단어와 내용은 그대로 둔다. 질문은 질문으로, 명령은 명령으로, 시제와 추측 표현도 그대로 유지한다. 바꾼 문장만 답한다."
    private static let japaneseRules = "文末と敬語表現だけを変え、ほかの語句と内容はそのまま残してください。疑問は疑問のまま、依頼や命令はそのまま、時制や推量（でしょう→だろう）も変えないでください。書き換えた文だけを答えてください。"

    // MARK: - Checking a rewrite

    /// Korean pronoun forms that change with the speech level; every other
    /// word but the last two has to survive a rewrite. Not a bare "저" or
    /// "제": "저 녀석" is "that guy", and must stay that.
    private static let koreanPronounForms: Set<String> = [
        "저는", "제가", "저도", "저를", "저의", "저에게", "저한테", "저희", "저희는", "저희가",
        "당신", "당신은", "당신이", "당신의", "당신을", "당신에게", "당신도", "당신한테",
    ]

    /// Words that carry meaning a rewrite must keep, and how they may read
    /// after it ("probably", "seems", "maybe", "should").
    private static let japaneseModality: [(String, [String])] = [
        ("でしょう", ["だろ", "でしょ"]), ("よう", ["よう"]), ("みたい", ["みたい"]), ("らしい", ["らしい"]),
        ("かもしれ", ["かも"]), ("はず", ["はず"]),
        // Negation ("いなければ" → "いれば" says the opposite) and how
        // clauses connect ("ですから" → "だから", not "だよね").
        ("ない", ["ない", "なく", "なけれ", "ず", "ん"]), ("ません", ["ない", "なく", "ず", "ん"]),
        ("なけれ", ["なけれ", "なきゃ", "ないと"]), ("から", ["から"]), ("ので", ["ので", "から"]),
        ("けど", ["けど"]), ("けれど", ["けど", "けれど"]), ("のに", ["のに"]),
    ]

    /// Beyond the level, nothing else about the sentence changed: still a
    /// question if it was one, the same words (Korean) or the same tense,
    /// modality and request (Japanese).
    private static func keepsTheSentence(_ rewrite: String, of draft: String, language: TranslationLanguage) -> Bool {
        let question: (String) -> Bool = { text in
            let end = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "…・.!！~〜")))
            return end.hasSuffix("?") || end.hasSuffix("？")
        }
        guard question(draft) == question(rewrite) else { return false }

        if language == .korean {
            let draftWords = draft.split(whereSeparator: \.isWhitespace).map(String.init)
            let kept = Set(rewrite.split(whereSeparator: \.isWhitespace).map(String.init))
            for word in draftWords.dropLast(2) where !kept.contains(word) && !koreanPronounForms.contains(word) {
                return false
            }
            // A negation stays ("없어" can't become "있어").
            for negation in ["않", "못", "없", "안 "] where draft.contains(negation) {
                guard rewrite.contains(negation) || (negation == "안 " && rewrite.contains("않")) else { return false }
            }
            // "모으세요" → "모으겠어" turns a request into an intention.
            guard draft.contains("겠") || !rewrite.contains("겠") else { return false }
            // A request stays one: "즐기세요" → "즐겨", not "즐기네".
            let lastWord: (String) -> String = { text in
                String(text.split(whereSeparator: \.isWhitespace).last ?? "")
                    .trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(CharacterSet(charactersIn: "…~")))
            }
            if ["세요", "십시오", "시오"].contains(where: lastWord(draft).hasSuffix) {
                return isCasualCommand(lastWord(rewrite))
            }
            return true
        }

        for (marker, kept) in japaneseModality where draft.contains(marker) {
            guard kept.contains(where: rewrite.contains) else { return false }
        }
        let tail: (String, Int) -> Substring = { text, count in
            text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).suffix(count)
        }
        // Past stays past ("なったのです" → "なった", not "なる").
        if tail(draft, 5).contains("た") || tail(draft, 5).contains("だっ"), !tail(rewrite, 4).contains("た") {
            return false
        }
        // A request stays one ("行動してください" → "行動して", not "行動してるよ").
        if draft.contains("てください") || draft.contains("でください") {
            let requests = ["て", "で", "てね", "でね", "てよ", "でよ", "てくれ", "でくれ", "なさい", "ろ", "ろよ"]
            guard requests.contains(where: tail(rewrite, 4).hasSuffix) else { return false }
        }
        // No passive or potential that wasn't there ("考えます" → "考えられる").
        return draft.contains("られ") || !rewrite.contains("られ")
    }

    /// A 반말 command: "-라", "-렴", "-자", "-게", or an open syllable on
    /// an a/eo vowel — 해, 줘, 봐, 즐겨, 와 (not "즐기네", "가야").
    private static func isCasualCommand(_ word: String) -> Bool {
        if ["라", "렴", "자", "게"].contains(where: word.hasSuffix) { return true }
        guard let last = word.unicodeScalars.last, isHangulSyllable(last) else { return false }
        let index = last.value - 0xAC00
        let hasFinal = index % 28 != 0
        let vowel = (index / 28) % 21
        // ㅏ ㅐ ㅓ ㅕ ㅘ ㅙ ㅝ
        return !hasFinal && [0, 1, 4, 6, 9, 10, 14].contains(vowel)
    }

    /// Whether `rewrite` can replace `draft`: in the right script, about as
    /// long, mostly the same words, and actually at `level` now.
    static func accepts(_ rewrite: String, replacing draft: String, language: TranslationLanguage, level: SpeechLevel) -> Bool {
        guard !rewrite.isEmpty, rewrite != draft else { return false }
        let ratio = Double(rewrite.count) / Double(max(1, draft.count))
        guard ratio > 0.5, ratio < 1.5 else { return false }
        func isContent(_ scalar: Unicode.Scalar) -> Bool {
            language == .korean ? isHangulSyllable(scalar) : isKana(scalar) || isKanji(scalar)
        }
        let letters = rewrite.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty, Double(letters.filter(isContent).count) / Double(letters.count) > 0.9 else { return false }
        let draftContent = draft.unicodeScalars.filter(isContent)
        let kept = Set(rewrite.unicodeScalars.filter(isContent))
        guard !draftContent.isEmpty, Double(draftContent.filter(kept.contains).count) / Double(draftContent.count) >= 0.6 else {
            return false
        }
        guard let now = Self.level(ofTranslation: rewrite, language: language), now.isPlain == level.isPlain else { return false }
        return keepsTheSentence(rewrite, of: draft, language: language)
    }

    /// The model's answer as a balloon's text: no quotes or label around it.
    static func cleaned(_ answer: String) -> String {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = text.split(separator: "\n").first, text.contains("\n") {
            text = String(firstLine)
        }
        for (open, close) in [("\"", "\""), ("“", "”"), ("「", "」")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 2 {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Scripts

    static func isHangulSyllable(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(scalar.value)
    }

    static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value)
    }

    static func isKanji(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
    }
}

/// Rewrites a translation to the original's speech level, or says to keep it.
nonisolated protocol SpeechLevelCorrecting: Sendable {
    /// The corrected translation, or `nil` to keep `translation` as it is
    /// (already matching, nothing to read, or the rewrite didn't check out).
    func correct(_ translation: String, source: String) async -> String?
}

/// Whether speech-level matching can run on this Mac.
nonisolated enum SpeechLevelAvailability: Equatable, Sendable {
    case available
    /// Apple Intelligence is off in System Settings.
    case appleIntelligenceOff
    /// This Mac can't run Apple Intelligence.
    case notEligible
    /// The model is still downloading.
    case notReady
    /// Before macOS 26.
    case unsupportedSystem

    static var current: SpeechLevelAvailability {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .unsupportedSystem }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.deviceNotEligible): return .notEligible
        case .unavailable: return .notReady
        }
        #else
        return .unsupportedSystem
        #endif
    }
}

#if canImport(FoundationModels)
/// The on-device model (Apple Intelligence) doing the rewrite.
@available(macOS 26.0, *)
nonisolated struct OnDeviceSpeechLevelCorrector: SpeechLevelCorrecting {
    let source: TranslationLanguage
    let target: TranslationLanguage

    /// `nil` when the pair has no speech levels to match or the model isn't
    /// there.
    static func make(from source: TranslationLanguage, to target: TranslationLanguage) -> OnDeviceSpeechLevelCorrector? {
        guard SpeechLevelRules.supports(from: source, to: target), SpeechLevelAvailability.current == .available else { return nil }
        return OnDeviceSpeechLevelCorrector(source: source, target: target)
    }

    func correct(_ translation: String, source text: String) async -> String? {
        guard let wanted = SpeechLevelRules.level(ofSource: text, language: source),
              let have = SpeechLevelRules.level(ofTranslation: translation, language: target),
              SpeechLevelRules.needsRewrite(translation: have, original: wanted)
        else { return nil }
        // The transformation guardrails: the text is the book's, and comics
        // are often violent or crude — the default ones refuse those.
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: SpeechLevelRules.instructions(for: target, level: wanted))
        do {
            let response = try await session.respond(to: translation, options: GenerationOptions(temperature: 0))
            let rewrite = SpeechLevelRules.cleaned(response.content)
            return SpeechLevelRules.accepts(rewrite, replacing: translation, language: target, level: wanted) ? rewrite : nil
        } catch {
            AppLog.debug(.reader, "Speech level rewrite failed", metadata: ["error": "\(error)"])
            return nil
        }
    }
}
#endif

/// The corrector for a pair, if it applies and the model is available.
nonisolated enum SpeechLevelCorrectors {
    static func make(from source: TranslationLanguage, to target: TranslationLanguage) -> (any SpeechLevelCorrecting)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return OnDeviceSpeechLevelCorrector.make(from: source, to: target)
        }
        #endif
        return nil
    }
}
