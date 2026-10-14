import Foundation
import NaturalLanguage

/// Recognizes onomatopoeia (スッ, ドサッ, パチパチ, 짝짝) so it can be left
/// untranslated. Sound effects are drawn art more than dialogue: translating
/// them costs a second each and mostly yields noise ("Suck", "Click-click").
/// Deliberately narrow — a short name like メラス or a reply like はい must
/// survive — so only the shapes sound effects take are matched.
nonisolated enum SoundEffectClassifier {
    static func isSoundEffect(_ text: String, language: TranslationLanguage) -> Bool {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty, letters.count <= 6 else { return false }
        // Kanji/hanzi carry meaning; never treat them as a sound.
        if letters.contains(where: { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }) {
            return false
        }
        let string = String(String.UnicodeScalarView(letters))
        switch language {
        case .japanese:
            return endsWithCatch(string) || endsWithSmallVowel(string) || hasLongVowelMark(string, letters: letters.count)
                || isRepetition(string, minimumUnit: 2) || isShortNasalBeat(string)
        case .korean:
            // "비켜, 비켜!", "꿈이 없다… 흠흠" — punctuation inside the text
            // means it's spoken, however much it repeats.
            guard !hasInnerPunctuation(text) else { return false }
            return isRepetition(string, minimumUnit: 1) || endsWithDoubledSyllable(string)
                || isVowelAlternation(string) || isLoneSyllable(text, letters: string)
        case .chineseSimplified, .chineseTraditional, .english:
            return false
        }
    }

    /// 타박박, 트두두, 물불불 — a sound that trails off in a doubled syllable.
    private static func endsWithDoubledSyllable(_ s: String) -> Bool {
        let characters = Array(s)
        return characters.count >= 3 && characters[characters.count - 1] == characters[characters.count - 2]
    }

    /// 푸벅푸백, 아장어정 — a two-syllable sound repeated with only its vowel
    /// changed (same initial and final consonants), the usual way Korean
    /// varies a sound.
    private static func isVowelAlternation(_ s: String) -> Bool {
        let syllables = s.unicodeScalars.compactMap(HangulSyllable.init)
        guard syllables.count == 4, s.unicodeScalars.count == 4 else { return false }
        func sameConsonants(_ a: HangulSyllable, _ b: HangulSyllable) -> Bool {
            a.initial == b.initial && a.final == b.final
        }
        return sameConsonants(syllables[0], syllables[2]) && sameConsonants(syllables[1], syllables[3])
            && (syllables[0] != syllables[2] || syllables[1] != syllables[3])
    }

    /// 쿵, 꿀, 투 — one syllable on its own with no punctuation is drawn
    /// lettering (or a piece of it that OCR split off). Lone replies keep
    /// their meaning and stay.
    private static func isLoneSyllable(_ text: String, letters: String) -> Bool {
        guard letters.count == 1, !koreanLoneWords.contains(letters) else { return false }
        return !text.contains { "?!.…~,".contains($0) }
    }

    private static let koreanLoneWords: Set<String> = ["응", "예", "네", "뭐", "왜"]

    /// Punctuation followed by more text; trailing "!", "…" and the like are
    /// part of how sound effects are lettered.
    private static func hasInnerPunctuation(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "?!.…~,·•:- ").union(.whitespaces))
        return body.contains { "?!.…,".contains($0) }
    }

    /// スッ, ドサッ, ぽすっ — a small tsu marks a cut-off sound.
    private static func endsWithCatch(_ s: String) -> Bool {
        guard let last = s.last else { return false }
        return last == "ッ" || last == "っ"
    }

    /// はあぁ, ひぃ — a trailing small vowel is a drawn-out breath or cry.
    private static func endsWithSmallVowel(_ s: String) -> Bool {
        guard let last = s.last else { return false }
        return "ぁぃぅぇぉァィゥェォ".contains(last)
    }

    /// ゴーン, ニャー — a long-vowel mark in a very short word.
    private static func hasLongVowelMark(_ s: String, letters: Int) -> Bool {
        letters <= 4 && s.contains("ー")
    }

    /// トン, ドン — two kana ending in ン.
    private static func isShortNasalBeat(_ s: String) -> Bool {
        s.count == 2 && (s.last == "ン" || s.last == "ん") && s.unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) }
    }

    /// パチパチ, 짝짝 — a unit repeated two or more times.
    static func isRepetition(_ s: String, minimumUnit: Int) -> Bool {
        let characters = Array(s)
        guard characters.count >= minimumUnit * 2 else { return false }
        for unit in minimumUnit...(characters.count / 2) where characters.count % unit == 0 {
            let head = characters[0..<unit]
            if stride(from: unit, to: characters.count, by: unit).allSatisfy({ characters[$0..<($0 + unit)] == head }) {
                return true
            }
        }
        return false
    }
}

/// A precomposed hangul syllable split into its jamo indices.
private nonisolated struct HangulSyllable: Equatable {
    let initial: UInt32
    let vowel: UInt32
    let final: UInt32

    init?(_ scalar: Unicode.Scalar) {
        guard (0xAC00...0xD7A3).contains(scalar.value) else { return nil }
        let index = scalar.value - 0xAC00
        initial = index / 588
        vowel = (index % 588) / 28
        final = index % 28
    }
}

/// Decides which language a page's text is in from the scripts it uses.
/// Script counts are decisive where it matters for comics: any kana means
/// Japanese (Japanese text mixes kanji in; Chinese has no kana), hangul means
/// Korean. Han-only text is Chinese, with `NLLanguageRecognizer` choosing
/// Simplified vs Traditional.
nonisolated enum TranslationLanguageClassifier {
    /// Fewer letters than this is too little to call.
    static let minimumLetters = 4

    static func classify(_ text: String) -> TranslationLanguage? {
        var kana = 0, hangul = 0, han = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: kana += 1
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        guard kana + hangul + han + latin >= minimumLetters else { return nil }
        // Latin letters per word are ~4× CJK characters per word; weight them
        // down so a few English signs don't outvote the dialogue.
        let scores: [(TranslationLanguage, Int)] = [
            (.japanese, kana > 0 ? kana + han : 0),
            (.korean, hangul),
            (.chineseSimplified, kana == 0 ? han : 0),
            (.english, latin / 4),
        ]
        guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        if best.0 == .chineseSimplified {
            let recognizer = NLLanguageRecognizer()
            recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
            recognizer.processString(text)
            return recognizer.dominantLanguage == .traditionalChinese ? .chineseTraditional : .chineseSimplified
        }
        return best.0
    }
}
