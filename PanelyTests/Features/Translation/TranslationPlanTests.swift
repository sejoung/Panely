import CoreGraphics
import Testing
@testable import Panely

struct TranslationPlanTests {
    /// 298 slices of 720 × 576 — the shape of the webtoon the strip scope was built for.
    private let slices = StripLayout(pageSizes: Array(repeating: CGSize(width: 720, height: 576), count: 298))

    @Test func stripLayoutStacksAndCentresPages() {
        let layout = StripLayout(pageSizes: [CGSize(width: 800, height: 100), CGSize(width: 600, height: 50)])
        #expect(layout.width == 800)
        #expect(layout.height == 150)
        #expect(layout.pageRect(1) == CGRect(x: 100, y: 100, width: 600, height: 50))
        #expect(layout.page(containingY: 0) == 0)
        #expect(layout.page(containingY: 99.9) == 0)
        #expect(layout.page(containingY: 100) == 1)
        #expect(layout.page(containingY: 10_000) == 1)
        #expect(layout.pages(intersecting: 90..<110) == [0, 1])
        #expect(layout.pages(intersecting: 100..<150) == [1])
    }

    @Test func stripBandsOwnTheWholeStripExactlyOnce() {
        let plan = TranslationPlan.strip(slices)
        let owned = plan.units.compactMap(\.band?.ownedRange)
        #expect(owned.first?.lowerBound == 0)
        #expect(owned.last?.upperBound == slices.height)
        for (a, b) in zip(owned, owned.dropFirst()) {
            #expect(a.upperBound == b.lowerBound)
        }
        // Every owned point sits at least half an overlap from its band's seams,
        // so balloons up to an overlap tall are read whole.
        for unit in plan.units {
            guard let band = unit.band else { continue }
            if !band.isFirst { #expect(band.ownedRange.lowerBound - band.top >= 499) }
            if !band.isLast { #expect(band.top + band.height - band.ownedRange.upperBound >= 499) }
        }
    }

    @Test func everyPageBelongsToSomeUnit() {
        let plan = TranslationPlan.strip(slices)
        let covered = Set(plan.units.flatMap(\.pageIndices))
        #expect(covered == Set(0..<298))
    }

    @Test func nextUnitFollowsTheReader() {
        let plan = TranslationPlan.pages(count: 10)
        #expect(plan.nextUnit(excluding: [], focusPage: 4)?.id == 4)
        #expect(plan.nextUnit(excluding: [4, 5], focusPage: 4)?.id == 6)
        // Everything from the focus on is done: go back for the earlier pages.
        #expect(plan.nextUnit(excluding: Set(3..<10), focusPage: 4)?.id == 0)
        #expect(plan.nextUnit(excluding: Set(0..<10), focusPage: 4) == nil)
    }

    @Test func pagesCompleteOnlyWhenAllTheirUnitsAreDone() {
        let plan = TranslationPlan.strip(slices)
        let first = plan.units[0]
        let done = plan.completedPages(finishedUnits: [first.id])
        // Pages shared with the second band aren't complete yet.
        let shared = Set(first.pageIndices).intersection(plan.units[1].pageIndices)
        #expect(done.isDisjoint(with: shared))
        #expect(!done.isEmpty)
        #expect(done.isSubset(of: Set(first.pageIndices)))
    }

    @Test func cachedPagesMarkTheirUnitsDone() {
        let plan = TranslationPlan.pages(count: 5)
        #expect(plan.unitsAlreadyDone(completePages: [1, 3]) == [1, 3])
    }

    @Test func storeKeyDependsOnScope() {
        #expect(
            TranslationStore.key(pageID: "p", from: .japanese, to: .korean, scope: .page)
                != TranslationStore.key(pageID: "p", from: .japanese, to: .korean, scope: .strip)
        )
    }
}

struct TextClassifierTests {
    @Test func japaneseSoundEffectsAreRecognized() {
        for sound in ["スッ", "ドサッ", "ぽすっ", "コクッ", "トン", "パチパチ", "ニャー", "ゴーン", "はあぁ・・"] {
            #expect(SoundEffectClassifier.isSoundEffect(sound, language: .japanese), "\(sound)")
        }
    }

    @Test func shortDialogueAndNamesAreKept() {
        for line in ["はい", "ええ", "メラス", "聖下", "神よ", "ふふ…", "キャロット！", "心からぁぁぁー"] {
            #expect(!SoundEffectClassifier.isSoundEffect(line, language: .japanese), "\(line)")
        }
    }

    @Test func koreanRepetitionIsASoundEffect() {
        #expect(SoundEffectClassifier.isSoundEffect("짝짝", language: .korean))
        #expect(!SoundEffectClassifier.isSoundEffect("후추!", language: .korean))
    }

    @Test func languageIsClassifiedByScript() {
        #expect(TranslationLanguageClassifier.classify("私はただ その御意志 従うのみ") == .japanese)
        #expect(TranslationLanguageClassifier.classify("당근아! 이런 귀여운 것") == .korean)
        #expect(TranslationLanguageClassifier.classify("Carrot! You're so cute to have thought of it") == .english)
        #expect(TranslationLanguageClassifier.classify("这场战争必须停止，无论付出什么代价") == .chineseSimplified)
        // A page with English signs but Japanese dialogue is Japanese.
        #expect(TranslationLanguageClassifier.classify("Contest Komona もう最高！私の魔法薬に") == .japanese)
        #expect(TranslationLanguageClassifier.classify("!!") == nil)
    }
}
