import CoreGraphics
import Foundation
import Testing
@testable import Panely

/// The reader's balloon edits: laid over the machine translation for display,
/// matched to balloons by their recognised text and place, and kept on disk
/// apart from the cache.
struct PageEditsTests {
    private let page = makeTranslatedPage("기계 번역")
    private var bubble: TranslatedBubble { page.bubbles[0] }

    @Test func noEditsLeavesThePageAsIs() {
        #expect(PageEdits().apply(to: page, target: .korean) == page)
    }

    @Test func hiddenBalloonsAreDropped() {
        var edits = PageEdits()
        edits.update(bubble) { $0.isHidden = true }

        #expect(edits.apply(to: page, target: .korean).bubbles.isEmpty)
        #expect(edits.translation(of: bubble, in: .korean) == nil)
        #expect(edits.hiddenCount == 1)
    }

    @Test func ownTranslationBelongsToItsLanguage() {
        var edits = PageEdits()
        edits.update(bubble) { $0.translations[TranslationLanguage.korean.rawValue] = "내 번역" }

        let korean = edits.apply(to: page, target: .korean).bubbles[0]
        #expect(korean.translation == "내 번역")
        #expect(korean.edit?.translationIsReaders == true)
        // Another language keeps its machine translation.
        #expect(edits.apply(to: page, target: .english).bubbles[0].translation == "기계 번역")
    }

    @Test func correctedOriginalShowsItsRetranslation() {
        var edits = PageEdits()
        edits.update(bubble) {
            $0.correctedSource = "正しい原文"
            $0.retranslations[TranslationLanguage.korean.rawValue] = "고친 원문의 번역"
        }

        let shown = edits.apply(to: page, target: .korean).bubbles[0]
        #expect(shown.translation == "고친 원문의 번역")
        #expect(shown.edit?.correctedSource == "正しい原文")
        #expect(shown.edit?.needsRetranslation == false)
        // The recognised text stays the balloon's identity.
        #expect(shown.source == bubble.source)
    }

    @Test func correctedOriginalWithoutRetranslationOffersOne() {
        var edits = PageEdits()
        edits.update(bubble) { $0.correctedSource = "正しい原文" }

        let waiting = edits.apply(to: page, target: .korean).bubbles[0]
        #expect(waiting.translation == "기계 번역")
        #expect(waiting.edit?.needsRetranslation == true)

        let inFlight = edits.apply(to: page, target: .korean, retranslating: [bubble.source]).bubbles[0]
        #expect(inFlight.translation == nil)
        #expect(inFlight.edit?.needsRetranslation == false)
    }

    @Test func ownTranslationWinsOverRetranslation() {
        var edits = PageEdits()
        edits.update(bubble) {
            $0.correctedSource = "正しい原文"
            $0.retranslations[TranslationLanguage.korean.rawValue] = "고친 원문의 번역"
            $0.translations[TranslationLanguage.korean.rawValue] = "내 번역"
        }

        #expect(edits.apply(to: page, target: .korean).bubbles[0].translation == "내 번역")
    }

    @Test func editsMatchByRecognizedTextAndPlace() {
        var edits = PageEdits()
        edits.update(bubble) { $0.isHidden = true }

        var elsewhere = bubble
        elsewhere.rect = bubble.rect.offsetBy(dx: 100, dy: 100)
        var otherText = bubble
        otherText.source = "別の原文"
        var reanalysed = bubble
        reanalysed.id = 7 // ids are only a count within one analysis

        #expect(edits.edit(for: elsewhere) == nil)
        #expect(edits.edit(for: otherText) == nil)
        #expect(edits.edit(for: reanalysed) != nil)
    }

    @Test func emptiedEditsAreDropped() {
        var edits = PageEdits()
        edits.update(bubble) { $0.translations[TranslationLanguage.korean.rawValue] = "내 번역" }
        edits.update(bubble) { $0.translations[TranslationLanguage.korean.rawValue] = nil }

        #expect(edits.isEmpty)
    }
}

struct TranslationEditStoreTests {
    private func makeStore() throws -> TranslationEditStore {
        TranslationEditStore(root: try Fixture.makeTempDir().appendingPathComponent("edits", isDirectory: true))
    }

    @Test func editsRoundTripAndEmptyEditsDeleteTheFile() throws {
        let store = try makeStore()
        let key = TranslationEditStore.key(pageID: "p1", scope: .page)
        var edits = PageEdits()
        edits.update(makeTranslatedPage().bubbles[0]) { $0.isHidden = true }

        try store.save(edits, key: key)
        #expect(store.load(key: key) == edits)
        #expect(store.pageCount() == 1)

        try store.save(PageEdits(), key: key)
        #expect(store.load(key: key) == nil)
        #expect(store.pageCount() == 0)
    }

    @Test func keyDependsOnPageAndScopeOnly() {
        let base = TranslationEditStore.key(pageID: "p1", scope: .page)
        #expect(base == TranslationEditStore.key(pageID: "p1", scope: .page))
        #expect(base != TranslationEditStore.key(pageID: "p2", scope: .page))
        #expect(base != TranslationEditStore.key(pageID: "p1", scope: .strip))
    }

    @Test func clearRemovesEverything() throws {
        let store = try makeStore()
        var edits = PageEdits()
        edits.update(makeTranslatedPage().bubbles[0]) { $0.isHidden = true }
        try store.save(edits, key: TranslationEditStore.key(pageID: "p1", scope: .page))
        try store.save(edits, key: TranslationEditStore.key(pageID: "p2", scope: .page))

        store.clear()

        #expect(store.pageCount() == 0)
    }
}

@MainActor
struct TranslationEditsModelTests {
    private func makeModel() throws -> TranslationEdits {
        TranslationEdits(store: TranslationEditStore(root: try Fixture.makeTempDir().appendingPathComponent("edits", isDirectory: true)))
    }

    @Test func showAllHiddenBringsBalloonsBack() async throws {
        let model = try makeModel()
        await model.load(pageIDs: ["p1"], scope: .page)
        let page = makeTranslatedPage()
        model.update(pageID: "p1", bubble: page.bubbles[0]) { $0.isHidden = true }
        #expect(model.hiddenCount == 1)
        #expect(model.apply(to: page, pageID: "p1", target: .korean).bubbles.isEmpty)

        model.showAllHidden()

        #expect(model.hiddenCount == 0)
        #expect(model.apply(to: page, pageID: "p1", target: .korean) == page)
    }

    @Test func hidingCanBeUndoneRightAway() async throws {
        let model = try makeModel()
        await model.load(pageIDs: ["p1"], scope: .page)
        let page = makeTranslatedPage()

        model.hide(pageID: "p1", bubble: page.bubbles[0])
        #expect(model.recentlyHidden?.pageID == "p1")
        #expect(model.hiddenCount == 1)

        model.undoHide()
        #expect(model.recentlyHidden == nil)
        #expect(model.hiddenCount == 0)
        #expect(model.apply(to: page, pageID: "p1", target: .korean) == page)
    }

    @Test func oneHiddenBalloonComesBackOnItsOwn() async throws {
        let model = try makeModel()
        await model.load(pageIDs: ["p1"], scope: .page)
        let first = makeTranslatedPage().bubbles[0]
        var second = first
        second.source = "別の原文"
        second.rect = first.rect.offsetBy(dx: 50, dy: 0)
        model.update(pageID: "p1", bubble: first) { $0.isHidden = true }
        model.update(pageID: "p1", bubble: second) { $0.isHidden = true }
        #expect(model.hiddenBalloons.count == 2)

        let target = try #require(model.hiddenBalloons.first { $0.edit.recognizedSource == "別の原文" })
        model.showHidden(pageID: target.pageID, edit: target.edit)

        #expect(model.hiddenBalloons.map(\.edit.recognizedSource) == [first.source])
    }

    @Test func revertingTheBookDropsEveryEditInIt() async throws {
        let model = try makeModel()
        await model.load(pageIDs: ["p1", "p2"], scope: .page)
        let bubble = makeTranslatedPage().bubbles[0]
        model.update(pageID: "p1", bubble: bubble) { $0.isHidden = true }
        model.update(pageID: "p2", bubble: bubble) { $0.translations[TranslationLanguage.korean.rawValue] = "내 번역" }
        #expect(model.editedCount == 2)

        model.revertAllInBook()

        #expect(model.editedCount == 0)
        #expect(model.hiddenCount == 0)
        // The files go too, so reopening the book doesn't bring them back.
        for _ in 0..<100 where model.store.pageCount() > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.store.pageCount() == 0)
    }

    @Test func retranslationLandsOnlyForTheCorrectionItWasFor() async throws {
        let model = try makeModel()
        await model.load(pageIDs: ["p1"], scope: .page)
        let bubble = makeTranslatedPage().bubbles[0]
        model.update(pageID: "p1", bubble: bubble) { $0.correctedSource = "最初の修正" }
        let stale = TranslationEdits.Retranslation(pageID: "p1", recognizedSource: bubble.source, correctedSource: "最初の修正", target: .korean)
        model.beginRetranslation(stale)
        // Corrected again before the first translation came back.
        model.update(pageID: "p1", bubble: bubble) { $0.correctedSource = "二度目の修正" }

        model.finishRetranslation(stale, bubble: bubble, text: "첫 수정의 번역")

        #expect(model.edits(forPage: "p1")?.edit(for: bubble)?.retranslations.isEmpty == true)
        #expect(model.retranslating.isEmpty)
    }

    @Test func editsSurviveReloadingTheBook() async throws {
        let model = try makeModel()
        await model.load(pageIDs: ["p1"], scope: .page)
        let bubble = makeTranslatedPage().bubbles[0]
        model.update(pageID: "p1", bubble: bubble) { $0.translations[TranslationLanguage.korean.rawValue] = "내 번역" }

        let reopened = TranslationEdits(store: model.store)
        // Saving runs in the background; wait for the file to land.
        for _ in 0..<100 where model.store.pageCount() == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        await reopened.load(pageIDs: ["p1"], scope: .page)

        #expect(reopened.edits(forPage: "p1")?.edit(for: bubble)?.translations[TranslationLanguage.korean.rawValue] == "내 번역")
    }
}
