import CoreGraphics
import Foundation
import Testing
@testable import Panely

/// Copying balloons for an AI chat and taking its reply back.
struct AIChatExchangeTests {
    private func page(_ translations: [String?], hiddenAt hidden: Int? = nil) -> TranslatedPage {
        TranslatedPage(imageWidth: 100, imageHeight: 100, bubbles: translations.enumerated().map { index, text in
            TranslatedBubble(
                id: index, rect: CGRect(x: 0, y: index * 10, width: 10, height: 8), glyphSize: 8, isVertical: false,
                source: "原文\(index)", translation: text, background: .white,
                edit: index == hidden ? BubbleEditState(correctedSource: nil, translationIsReaders: false, needsRetranslation: false, isHidden: true) : nil
            )
        })
    }

    @Test func balloonsAreNumberedByPageInReadingOrder() {
        let lines = AIChatExchange.lines(pages: [
            (index: 11, pageID: "b", page: page(["둘-하나", "둘-둘"])),
            (index: 2, pageID: "a", page: page(["하나", "", nil, "숨김"], hiddenAt: 3)),
        ])

        // Untranslated, failed and hidden balloons are left out.
        #expect(lines.map(\.id) == ["p3-1", "p12-1", "p12-2"])
        #expect(lines.map(\.translation) == ["하나", "둘-하나", "둘-둘"])
        #expect(lines.first?.source == "原文0")
    }

    @Test func theFileListsEachBalloonWithItsIdUnderAHeader() {
        let lines = AIChatExchange.lines(pages: [(index: 0, pageID: "a", page: page(["여기는\n어디입니까?", "둘"]))])
        let file = AIChatExchange.fileText(lines, title: "Book", from: .japanese, to: .korean)

        #expect(file.hasPrefix("# Panely — \"Book\" — Japanese → Korean — 2 balloons, page 1\n"))
        #expect(file.contains("\n[p1-1] 原文0 → 여기는 / 어디입니까?\n"))
        #expect(file.hasSuffix("[p1-2] 原文1 → 둘\n"))
        // The header can't be mistaken for a reply line.
        #expect(AIChatExchange.parse(file).count == 2)
    }

    @Test func thePromptNamesTheFileAndAsksForEveryBalloon() {
        let prompt = AIChatExchange.prompt(fileName: "Book p1 [ko].txt", balloons: 42, from: "Japanese", to: "Korean")

        #expect(prompt.contains("Book p1 [ko].txt"))
        #expect(prompt.contains("42"))
        #expect(prompt.contains("[id] translation"))
    }

    @Test func repliesAreReadHoweverTheChatFormatsThem() {
        let reply = """
        Here are the improved translations:
        ```
        [p1-1] 여기가 어디지?
        - [p1-2]: “드디어 깼구나.”
        **[p2-1]** 原文 → 꿈을 꾼 것 같아 / 정말로
        [p2-2]
        ```
        Let me know if you need anything else!
        """

        let parsed = AIChatExchange.parse(reply)

        #expect(parsed == ["p1-1": "여기가 어디지?", "p1-2": "드디어 깼구나.", "p2-1": "꿈을 꾼 것 같아\n정말로"])
    }

    @Test func aReplySaysWhatChangedWhatWasRightAndWhatItDoesntKnow() {
        let lines = AIChatExchange.lines(pages: [(index: 0, pageID: "a", page: page(["하나", "둘"]))])

        let changes = AIChatExchange.changes(from: ["p1-1": "첫째", "p1-2": "둘", "p9-1": "?"], lines: lines)

        #expect(changes.updates.map(\.line.id) == ["p1-1"])
        #expect(changes.updates.map(\.text) == ["첫째"])
        #expect(changes.unchanged == 1)
        #expect(changes.unknown == 1)
        #expect(changes.missing.isEmpty)
    }

    /// A chat that stops short — a long book, a limit — leaves balloons out;
    /// they're named, in reading order.
    @Test func balloonsTheReplyLeftOutAreNamed() {
        let lines = AIChatExchange.lines(pages: [
            (index: 0, pageID: "a", page: page(["하나", "둘"])),
            (index: 1, pageID: "b", page: page(["셋"])),
        ])

        let changes = AIChatExchange.changes(from: ["p1-1": "첫째"], lines: lines)

        #expect(changes.missing == ["p1-2", "p2-1"])
        #expect(changes.returned == 1)
    }
}

@MainActor
struct ReaderViewModelAIChatTests {
    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func aReplyBecomesTheReadersTranslationsAndUndoesInOneGo() async throws {
        let vm = makeTestViewModel()
        vm.translationEnabled = true
        vm.translationTargetLanguage = .korean
        let pages = Fixture.makeImagePages(count: 1)
        try vm.translation.store.save(makeTranslatedPage("기계 번역"), key: TranslationStore.key(pageID: pages[0].id, from: .japanese, to: .korean))
        vm.currentSourceURL = URL(fileURLWithPath: "/books/test")
        vm.source = ComicSource(title: "Test", pages: pages)
        try await waitUntil { vm.translation.bookPageCount == 1 }
        vm.translation.setSource(.japanese)
        try await waitUntil { !vm.translation.pages.isEmpty }
        await vm.translationEdits.load(pageIDs: pages.map(\.id), scope: .page)

        let file = vm.aiChatFile(for: .book)
        #expect(file.balloons == 1)
        #expect(file.text.contains("[p1-1] 原文 → 기계 번역"))
        #expect(file.fileName == "Test p1 [ko].txt")
        #expect(vm.aiChatPromptText(fileName: file.fileName, balloons: file.balloons).contains(file.fileName))

        let changes = vm.applyAIChatReply("[p1-1] 문맥에 맞춘 번역")
        #expect(changes.updates.count == 1)
        #expect(vm.translationOverlayPagesForTesting(pages[0].id) == "문맥에 맞춘 번역")
        #expect(vm.translationEdits.editedCount == 1)

        vm.undoAIChatReply()
        #expect(vm.translationOverlayPagesForTesting(pages[0].id) == "기계 번역")
        #expect(vm.translationEdits.editedCount == 0)
        #expect(vm.aiChatUndo == nil)
    }
}

private extension ReaderViewModel {
    /// The shown translation of a page's first balloon, edits applied.
    func translationOverlayPagesForTesting(_ pageID: String) -> String? {
        guard let machine = translation.pages[pageID] else { return nil }
        return translationEdits.apply(to: machine, pageID: pageID, target: translation.target).bubbles.first?.translation
    }
}

/// The prompt is the longest string in the catalog; a key off by a
/// character would silently show it in English only.
struct AIChatPromptLocalizationTests {
    @Test func thePromptIsTranslated() throws {
        let path = try #require(Bundle.main.path(forResource: "ko", ofType: "lproj"))
        let table = try #require(NSDictionary(contentsOfFile: path + "/Localizable.strings") as? [String: String])
        let (key, korean) = try #require(table.first { $0.key.hasPrefix("The attached file") })
        #expect(korean.hasPrefix("첨부한 파일"))

        let prompt = AIChatExchange.prompt(fileName: "F.txt", balloons: 3, from: "A", to: "B")

        // Whichever language the app runs in, the prompt is the catalog's.
        let english = String(format: key, "F.txt", 3, "A", "B")
        let translated = String(format: korean, "F.txt", 3, "A", "B")
        #expect(prompt == english || prompt == translated)
        #expect(translated.contains("“F.txt”에는 만화의 말풍선 3개"))
    }
}
