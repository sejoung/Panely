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

    @Test func editModeKeepsHiddenBalloonsMarked() {
        var edits = PageEdits()
        edits.update(bubble) { $0.isHidden = true }

        let editing = edits.apply(to: page, target: .korean, includeHidden: true)
        #expect(editing.bubbles.count == 1)
        #expect(editing.bubbles[0].edit?.isHidden == true)
        #expect(edits.apply(to: page, target: .korean).bubbles.isEmpty)
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
        try await waitUntil { model.store.pageCount() == 0 }
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
        try await waitUntil { model.store.pageCount() == 1 }
        await reopened.load(pageIDs: ["p1"], scope: .page)

        #expect(reopened.edits(forPage: "p1")?.edit(for: bubble)?.translations[TranslationLanguage.korean.rawValue] == "내 번역")
    }

    /// An AI chat reply's changes land together: the same edits as one at a
    /// time, one file per page.
    @Test func aBatchOfChangesMatchesThemOneByOne() async throws {
        let first = makeTranslatedPage().bubbles[0]
        var second = first
        second.id = 1
        second.source = "別の原文"
        second.rect = CGRect(x: 20, y: 30, width: 5, height: 5)
        let changes: [(String, TranslatedBubble, String?)] = [
            ("p1", first, "하나"), ("p1", second, "둘"), ("p2", first, "셋"), ("p1", first, nil),
        ]
        let korean = TranslationLanguage.korean.rawValue

        let oneByOne = try makeModel()
        await oneByOne.load(pageIDs: ["p1", "p2"], scope: .page)
        for (pageID, bubble, text) in changes {
            oneByOne.update(pageID: pageID, bubble: bubble) { $0.translations[korean] = text }
        }
        let batched = try makeModel()
        await batched.load(pageIDs: ["p1", "p2"], scope: .page)
        batched.update(changes.map { pageID, bubble, text in
            .init(pageID: pageID, bubble: bubble) { $0.translations[korean] = text }
        })

        #expect(batched.pages == oneByOne.pages)
        #expect(batched.edits(forPage: "p1")?.edit(for: first) == nil)
        #expect(batched.edits(forPage: "p1")?.edit(for: second)?.translations[korean] == "둘")
        try await waitUntil { batched.store.pageCount() == 2 }
    }
}

/// Balloons the reader adds over text the analysis missed.
struct AddedBalloonTests {
    private let page = makeTranslatedPage("기계 번역")
    private let area = CGRect(x: 4, y: 5, width: 3, height: 2)

    private func added(_ text: String = "はあ…") -> BubbleEdit {
        BubbleEdit(recognizedSource: text, rect: area, added: AddedBalloon(glyphSize: 2, isVertical: true, background: .white))
    }

    @Test func anAddedBalloonShowsWithItsTranslation() {
        var edits = PageEdits()
        var edit = added()
        edit.retranslations[TranslationLanguage.korean.rawValue] = "하아…"
        edits.add(edit)

        let shown = edits.apply(to: page, target: .korean).bubbles
        #expect(shown.count == 2)
        let balloon = try? #require(shown.last)
        #expect(balloon?.translation == "하아…")
        #expect(balloon?.edit?.isAdded == true)
        #expect(balloon?.id == PageEdits.addedBubbleID(0))
        // The page's own balloon is untouched.
        #expect(shown.first == page.bubbles.first)
    }

    @Test func withNothingToShowItsOutlinedWhileEditingAndLeftOutWhileReading() {
        var edits = PageEdits()
        edits.add(added(""))

        #expect(edits.apply(to: page, target: .korean).bubbles.count == 1)
        let editing = edits.apply(to: page, target: .korean, includeHidden: true).bubbles
        #expect(editing.count == 2)
        #expect(editing.last?.translation == nil)
        // Nothing read: nothing to translate until the text is typed.
        #expect(editing.last?.edit?.needsRetranslation == false)
    }

    @Test func anotherLanguageAsksToBeTranslatedAndTheReadersOwnWins() {
        var edits = PageEdits()
        var edit = added()
        edit.retranslations[TranslationLanguage.korean.rawValue] = "하아…"
        edits.add(edit)

        #expect(edits.apply(to: page, target: .english, includeHidden: true).bubbles.last?.edit?.needsRetranslation == true)

        edits.update(source: edit.recognizedSource, rect: edit.rect) { $0.translations[TranslationLanguage.korean.rawValue] = "후우…" }
        #expect(edits.apply(to: page, target: .korean).bubbles.last?.translation == "후우…")
        #expect(edits.bubbles.count == 1)
    }

    @Test func editsToThePagesOwnBalloonNeverLandOnAnAddedOne() {
        var edits = PageEdits()
        // Same text, overlapping place.
        let pageBubble = page.bubbles[0]
        edits.add(BubbleEdit(recognizedSource: pageBubble.source, rect: pageBubble.rect.insetBy(dx: 1, dy: 1), added: AddedBalloon(glyphSize: 2, isVertical: true, background: .white)))

        edits.update(pageBubble) { $0.isHidden = true }

        #expect(edits.bubbles.count == 2)
        #expect(edits.edit(for: pageBubble)?.isHidden == true)
        #expect(edits.bubbles.first?.isHidden == false)
    }

    @Test func whatGetsTranslated() {
        #expect(added().sourceToTranslate == "はあ…")
        #expect(added("").sourceToTranslate == nil)
        var corrected = added("")
        corrected.correctedSource = "はあ"
        #expect(corrected.sourceToTranslate == "はあ")
        // A page balloon's own text isn't retranslated unless corrected.
        #expect(BubbleEdit(recognizedSource: "原文", rect: area).sourceToTranslate == nil)
    }
}

@MainActor
struct AddedBalloonModelTests {
    private func makeModel() throws -> TranslationEdits {
        TranslationEdits(store: TranslationEditStore(root: try Fixture.makeTempDir().appendingPathComponent("edits", isDirectory: true)))
    }

    private func added(_ text: String) -> BubbleEdit {
        BubbleEdit(recognizedSource: text, rect: CGRect(x: 1, y: 1, width: 5, height: 5), added: AddedBalloon(glyphSize: 2, isVertical: false, background: .white))
    }

    @Test func addingOffersUndoAndSaysWhenNothingWasRead() async throws {
        let model = try makeModel()
        await model.load(pageIDs: ["p1"], scope: .page)

        model.add(pageID: "p1", edit: added(""))
        #expect(model.recentlyAdded?.foundNoText == true)
        #expect(model.addedCount == 1)

        model.undoAdd()
        #expect(model.addedCount == 0)
        #expect(model.recentlyAdded == nil)
    }

    @Test func itsTranslationLandsOnIt() async throws {
        let model = try makeModel()
        await model.load(pageIDs: ["p1"], scope: .page)
        let edit = added("はあ…")
        model.add(pageID: "p1", edit: edit)
        let bubble = TranslatedBubble(id: 0, rect: edit.rect, glyphSize: 2, isVertical: false, source: edit.recognizedSource, translation: nil, background: .white)
        let retranslation = TranslationEdits.Retranslation(pageID: "p1", recognizedSource: edit.recognizedSource, correctedSource: "はあ…", target: .korean)
        model.beginRetranslation(retranslation)

        model.finishRetranslation(retranslation, bubble: bubble, text: "하아…")

        #expect(model.edits(forPage: "p1")?.bubbles.first?.retranslations[TranslationLanguage.korean.rawValue] == "하아…")
    }
}
