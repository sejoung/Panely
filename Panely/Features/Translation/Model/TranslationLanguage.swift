import Foundation

/// Languages the translation assist reads from and translates into — the set
/// both Vision's document recognizer and Apple Translation cover for comics.
nonisolated enum TranslationLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case japanese = "ja"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case korean = "ko"
    case english = "en"

    var id: String { rawValue }

    var localeLanguage: Locale.Language { Locale.Language(identifier: rawValue) }

    /// Name in the interface language ("Japanese", "일본어").
    func displayName(in locale: Locale) -> String {
        locale.localizedString(forIdentifier: rawValue) ?? rawValue
    }

    /// Translating into the interface language is the obvious default; for an
    /// interface language we can't translate into, fall back to English.
    static func defaultTarget(forInterfaceLanguage code: String) -> TranslationLanguage {
        TranslationLanguage(rawValue: code) ?? .english
    }

    /// Joins text recognized on separate lines/columns of one balloon.
    /// Japanese and Chinese run straight on; Korean and English break lines
    /// between words, so the space has to come back ("되면" + "새차" →
    /// "되면 새차", not "되면새차").
    var lineJoiner: String {
        switch self {
        case .korean, .english: " "
        case .japanese, .chineseSimplified, .chineseTraditional: ""
        }
    }

    /// Whether comics in this language set balloons in vertical columns.
    /// Korean and English editions letter horizontally, even in the narrow
    /// balloons of a translated manga.
    var isWrittenVertically: Bool {
        switch self {
        case .japanese, .chineseSimplified, .chineseTraditional: true
        case .korean, .english: false
        }
    }

    /// Whether `text` contains this language's own script. OCR also picks up
    /// decorative glyphs, page numbers and stray Latin noise in the artwork;
    /// none of that is worth translating, and it's cheaper to drop it here
    /// than to send it through the translator.
    func containsOwnScript(_ text: String) -> Bool {
        switch self {
        case .japanese:
            return text.unicodeScalars.contains { Self.isKana($0) || Self.isHan($0) }
        case .chineseSimplified, .chineseTraditional:
            return text.unicodeScalars.contains(where: Self.isHan)
        case .korean:
            return text.unicodeScalars.contains(where: Self.isHangul)
        case .english:
            return text.unicodeScalars.filter { $0.isASCII && $0.properties.isAlphabetic }.count >= 2
        }
    }

    private static func isKana(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: true
        default: false
        }
    }

    private static func isHan(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: true
        default: false
        }
    }

    private static func isHangul(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: true
        default: false
        }
    }
}
