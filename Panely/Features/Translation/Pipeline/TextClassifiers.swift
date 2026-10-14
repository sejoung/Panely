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
            return isRepetition(string, minimumUnit: 1)
        case .chineseSimplified, .chineseTraditional, .english:
            return false
        }
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
