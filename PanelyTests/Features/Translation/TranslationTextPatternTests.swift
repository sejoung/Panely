import CryptoKit
import Foundation
import Testing
@testable import Panely

/// The title, text and key helpers were rewritten for speed (regexes compiled
/// once, hex without `String(format:)`). What they produce is load-bearing —
/// series membership, what the translator is sent, and the names cached
/// translations are found by — so each is checked against the code as it was
/// before, over tricky inputs and a seeded fuzz.
struct TranslationTextPatternTests {
    // MARK: - References (the code as it was)

    /// `SeriesVolumeMatcher.titleStem` before its patterns were compiled once.
    private static func referenceTitleStem(_ name: String) -> String {
        var title = name
        let ext = (name as NSString).pathExtension.lowercased()
        if ArchiveLoader.supportedExtensions.contains(ext) {
            title = (name as NSString).deletingPathExtension
        }
        title = title.lowercased()
        title = title.replacing(try! Regex(#"[\[\(\{【（][^\]\)\}】）]*[\]\)\}】）]"#), with: " ")
        title = title.replacing(try! Regex(#"(?:volume|vol|ch(?:apter)?|ep(?:isode)?|v|#)\s*\.?\s*[0-9０-９]+"#), with: " ")
        title = title.replacing(try! Regex(#"[0-9０-９]+\s*(?:권|화|부|巻|話|卷|集)"#), with: " ")
        title = title.replacing(try! Regex(#"(?:제|第)\s*[0-9０-９]+"#), with: " ")
        title = title.replacing(try! Regex(#"[0-9０-９]+"#), with: " ")
        return title.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// `TranslationTextNormalizer.normalize` before its patterns were compiled once.
    private static func referenceNormalize(_ text: String, language: TranslationLanguage) -> String {
        var result = text.replacingOccurrences(of: "\n", with: language.lineJoiner)
        result = result.replacing(try! Regex("[・•⋯…‥.。]{2,}"), with: "…")
        result = result.replacing(try! Regex(" {2,}"), with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `TranslationStore.key` before the hex encoding was hand-rolled.
    private static func referenceKey(
        pageID: String, from source: TranslationLanguage, to target: TranslationLanguage,
        scope: TranslationScope, mode: TranslationMode
    ) -> String {
        let modeTag = mode == .accurate ? "" : "|\(mode.rawValue)"
        let composite = "\(pageID)|\(source.rawValue)>\(target.rawValue)|\(scope.rawValue)\(modeTag)|v\(TranslatedPage.formatVersion)"
        return SHA256.hash(data: Data(composite.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Series titles

    private static let trickyTitles = [
        "One Piece v01.cbz", "One Piece Vol.02 (Digital) [Group].cbz", "ONE PIECE VOLUME 3.zip", "One Piece vol 4.rar",
        "One Piece ｖ０５.cbz", "One Piece vol.２.cbz", "One Piece ch１２", "One Piece #６", "One Piece #6.cbr", "One Piece ch. 12.cbz", "One Piece Chapter12.cbz", "One Piece ep 4",
        "One Piece episode5", "One Piece 1-294 완결", "[Group] (Digital) {tag} One Piece 01.cbz", "【中文】 One Piece 1集.cbz",
        "（完）One Piece.cbz", "[a [b] c] One Piece", "[unclosed One Piece 3", "One Piece (v2) 1부.zip",
        "세평유 1화.cbz", "세평유 １화.cbz", "세평유 제2화.cbz", "세평유 제 ３ 화.cbz", "세평유 10 권.cbz", "세평유2권",
        "ワンピース 第1巻.cbz", "ワンピース 第１０巻.cbz", "ワンピース 3巻.zip", "進撃の巨人 3話.zip", "進撃の巨人 第３話",
        "鬼滅の刃 卷4", "鬼滅の刃 4 卷", "名探偵 1集.cbz", "Berserk.cbz.cbz", "Berserk.pdf", "Berserk v", "volume",
        "01.cbz", "02", "", "제", "第", "#", "ch1ch2", "Title 1 - 5", "Évangile v01.cbz", "🔥Fire Force v01.cbz",
        "x-men 01.cbz", "Re:Zero 1권.cbz", "Re：Zero １권", "v1v2v3", "Vagabond_v01_(2003)_[Scan].cbz",
    ]

    @Test func seriesTitleStemsAreUnchanged() {
        for title in Self.trickyTitles {
            #expect(SeriesVolumeMatcher.titleStem(title) == Self.referenceTitleStem(title), "\(title)")
        }
        // A few pinned outright, so the reference can't drift with the code.
        #expect(SeriesVolumeMatcher.titleStem("[Group] One Piece Vol.02 (Digital).cbz") == "onepiece")
        // The counted number goes first, leaving its 제/第 behind — the same
        // for every volume, so they still match each other.
        #expect(SeriesVolumeMatcher.titleStem("세평유 제 ３ 화.cbz") == "세평유제")
        #expect(SeriesVolumeMatcher.titleStem("ワンピース 第１０巻.cbz") == "ワンピース第")
        #expect(SeriesVolumeMatcher.titleStem("ワンピース 第１０") == "ワンピース")
        #expect(SeriesVolumeMatcher.titleStem("鬼滅の刃 4 卷") == "鬼滅の刃")
        #expect(SeriesVolumeMatcher.titleStem("名探偵 1集.cbz") == "名探偵")
        #expect(SeriesVolumeMatcher.titleStem("01.cbz") == "")
        #expect(SeriesVolumeMatcher.titleStem("Berserk.pdf") == "berserkpdf")
    }

    @Test func seriesTitleStemsAreUnchangedOverAFuzz() {
        let pieces = [
            "v", "vol", "Vol.", "volume", "ch", "chapter", "ep", "episode", "#", " ", ".", "-", "_", "1", "07", "１", "２３",
            "권", "화", "부", "巻", "話", "卷", "集", "제", "第", "[", "]", "(", ")", "{", "}", "【", "】", "（", "）",
            "One", "piece", "세평유", "ワンピース", "é", "Ⅻ", ".cbz", ".zip", ".pdf",
        ]
        var random = TranslationTestRandom(seed: 0x5EED_0001)
        for _ in 0..<400 {
            let title = (0..<Int.random(in: 1...9, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
            #expect(SeriesVolumeMatcher.titleStem(title) == Self.referenceTitleStem(title), "\(title)")
        }
    }

    /// Which neighbours count as the series follows from the stems: checked
    /// on a folder mixing two works and every marker style.
    @Test func seriesVolumesAreUnchangedForAMixedFolder() {
        let folder = URL(fileURLWithPath: "/Comics")
        let siblings = Self.trickyTitles.filter { !$0.isEmpty }.map { folder.appendingPathComponent($0) }
        let stems = siblings.map { Self.referenceTitleStem($0.lastPathComponent) }
        for (index, book) in siblings.enumerated() {
            let expected = siblings.indices
                .filter { $0 != index && siblings[$0].standardizedFileURL != book.standardizedFileURL && stems[$0] == stems[index] }
                .map { siblings[$0] }
            #expect(SeriesVolumeMatcher.volumes(matching: book, among: siblings) == expected, "\(book.lastPathComponent)")
        }
    }

    // MARK: - OCR text

    @Test func normalizedTextIsUnchanged() {
        let texts = [
            "ここは・・どこ", "まって••", "えっと⋯⋯", "嘘...", "…。", "はあ‥‥", "。。", ".", "・", "a  b   c", "  前後  ",
            "一行目\n二行目", "line one\nline two", "둘째\n줄", "\n\n", "", "..\n..", "Wait . . . what", "・ ・", "…………",
            "混在・•⋯…‥.。end", "tab\there", "full　width　space",
        ]
        for text in texts {
            for language in TranslationLanguage.allCases {
                #expect(TranslationTextNormalizer.normalize(text, language: language) == Self.referenceNormalize(text, language: language), "\(text) \(language)")
            }
        }
        #expect(TranslationTextNormalizer.normalize("ここは・・どこ\n？", language: .japanese) == "ここは…どこ？")
        #expect(TranslationTextNormalizer.normalize("  what...  now  ", language: .english) == "what… now")
    }

    @Test func normalizedTextIsUnchangedOverAFuzz() {
        let pieces = ["・", "•", "⋯", "…", "‥", ".", "。", " ", "  ", "\n", "あ", "가", "a", "?", "！", "　"]
        var random = TranslationTestRandom(seed: 0x5EED_0002)
        for _ in 0..<400 {
            let text = (0..<Int.random(in: 0...12, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
            let language = TranslationLanguage.allCases.randomElement(using: &random)!
            #expect(TranslationTextNormalizer.normalize(text, language: language) == Self.referenceNormalize(text, language: language), "\(text.debugDescription)")
        }
    }

    // MARK: - Cache keys

    /// Every pair, scope and mode, over page ids with the characters real
    /// ones carry (paths, archive entries, non-ASCII names): the names
    /// cached translations are stored under mustn't change.
    @Test func cacheKeysAreUnchangedForEveryPairScopeAndMode() {
        let pageIDs = [
            "", "p1", "file:/Comics/One Piece/v01/001.png#1024:1700000000",
            "archive:/Comics/세평유 1화.cbz!/01.jpg#2:3", "file:/漫画/ワンピース/第1巻/０１.png", "🔥|>|v2", String(repeating: "x", count: 600),
        ]
        var checked = 0
        for pageID in pageIDs {
            for source in TranslationLanguage.allCases {
                for target in TranslationLanguage.allCases {
                    for scope in [TranslationScope.page, .strip] {
                        for mode in TranslationMode.allCases {
                            let key = TranslationStore.key(pageID: pageID, from: source, to: target, scope: scope, mode: mode)
                            #expect(key == Self.referenceKey(pageID: pageID, from: source, to: target, scope: scope, mode: mode))
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked == pageIDs.count * 5 * 5 * 2 * 2)
    }
}

/// SplitMix64: the same sequence every run, so a failing fuzz case reproduces.
struct TranslationTestRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
