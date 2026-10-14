import CoreGraphics
import Testing
@testable import Panely

struct BubbleGrouperTests {
    private func vertical(_ text: String, x: CGFloat, y: CGFloat, height: CGFloat, width: CGFloat = 60) -> TextRegion {
        TextRegion(text: text, rect: CGRect(x: x, y: y, width: width, height: height), isVertical: true, glyphSize: width)
    }

    private func horizontal(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 40) -> TextRegion {
        TextRegion(text: text, rect: CGRect(x: x, y: y, width: width, height: height), isVertical: false, glyphSize: height)
    }

    @Test func verticalColumnsOfOneBalloonMergeRightToLeft() {
        // 「私はただ／その御意志に従うのみ」: one balloon that Vision returned as
        // two paragraphs, the first column on the right.
        let right = vertical("私はただ", x: 374, y: 12409, height: 335, width: 110)
        let left = vertical("その御意志に\n従うのみ", x: 185, y: 12412, height: 469, width: 100)

        let bubbles = BubbleGrouper.group([left, right], language: .japanese)

        #expect(bubbles.count == 1)
        #expect(bubbles[0].source == "私はただその御意志に従うのみ")
        #expect(bubbles[0].isVertical)
        #expect(bubbles[0].rect == right.rect.union(left.rect))
    }

    @Test func separateBalloonsStayApart() {
        // Same height on the page, but far apart horizontally.
        let a = vertical("聖下", x: 1200, y: 100, height: 200)
        let b = vertical("アッシャー卿が", x: 300, y: 100, height: 400)
        // Directly below `a`, not beside it.
        let c = vertical("お待ちでございます", x: 1200, y: 900, height: 500)

        let bubbles = BubbleGrouper.group([a, b, c], language: .japanese)

        #expect(bubbles.count == 3)
    }

    @Test func stackedHorizontalLinesMerge() {
        // Two 40 px lines, then the name in a bigger size just below.
        let lines = TextRegion(
            text: "魅惑の天才を迎えることが\nできて光栄です",
            rect: CGRect(x: 60, y: 420, width: 380, height: 80),
            isVertical: false,
            glyphSize: 40
        )
        let name = horizontal("コリアンダー！", x: 100, y: 505, width: 300, height: 50)

        let bubbles = BubbleGrouper.group([name, lines], language: .japanese)

        #expect(bubbles.count == 1)
        #expect(bubbles[0].source == "魅惑の天才を迎えることができて光栄ですコリアンダー！")
    }

    @Test func horizontalAndVerticalTextNeverMerge() {
        let bubbles = BubbleGrouper.group([
            vertical("すべてが", x: 100, y: 100, height: 300),
            horizontal("灰と化す", x: 40, y: 100, width: 300),
        ], language: .japanese)
        #expect(bubbles.count == 2)
    }

    @Test func textWithoutTheSourceScriptIsDropped() {
        let bubbles = BubbleGrouper.group([
            horizontal("T", x: 0, y: 0, width: 20),
            horizontal("Sasaky u", x: 0, y: 200, width: 200),
            horizontal("40", x: 0, y: 400, width: 40),
            vertical("…いつから？", x: 500, y: 0, height: 300),
        ], language: .japanese)

        #expect(bubbles.map(\.source) == ["…いつから？"])
    }

    @Test func englishLinesJoinWithSpaces() {
        let bubbles = BubbleGrouper.group([
            horizontal("As Mayor of Komona,", x: 0, y: 0, width: 300),
            horizontal("I declare the contest open!", x: 0, y: 44, width: 360),
        ], language: .english)

        #expect(bubbles.map(\.source) == ["As Mayor of Komona, I declare the contest open!"])
    }

    @Test func normalizerCollapsesEllipsisVariants() {
        #expect(TranslationTextNormalizer.normalize("行わ・なければ・・。", language: .japanese) == "行わ・なければ…")
        #expect(TranslationTextNormalizer.normalize("見つめていた••。", language: .japanese) == "見つめていた…")
        #expect(TranslationTextNormalizer.normalize("⋯・・いつから？", language: .japanese) == "…いつから？")
        #expect(TranslationTextNormalizer.normalize("Wait...", language: .english) == "Wait…")
    }

    @Test func scriptDetectionPerLanguage() {
        #expect(TranslationLanguage.japanese.containsOwnScript("スッ"))
        #expect(TranslationLanguage.japanese.containsOwnScript("聖下"))
        #expect(!TranslationLanguage.japanese.containsOwnScript("KO•."))
        #expect(TranslationLanguage.korean.containsOwnScript("짝짝"))
        #expect(!TranslationLanguage.korean.containsOwnScript("パチ"))
        #expect(TranslationLanguage.chineseSimplified.containsOwnScript("战争"))
        #expect(TranslationLanguage.english.containsOwnScript("Hi"))
        #expect(!TranslationLanguage.english.containsOwnScript("7889"))
    }
}
