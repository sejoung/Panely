import CoreGraphics
import Foundation
import Testing
@testable import Panely

/// Opening a book reads its cached translations from one directory listing
/// (`TranslationStore.existingKeys`) instead of trying every page's key.
@MainActor
struct TranslationCacheLoadTests {
    private func page(_ text: String, complete: Bool = true) -> TranslatedPage {
        var page = makeTranslatedPage(text)
        page.isComplete = complete
        return page
    }

    private func load(_ store: TranslationStore, _ pages: [ComicPage], mode: TranslationMode, scope: TranslationScope = .page) async -> TranslationController {
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore())
        controller.reload(
            pages: pages, pageSizes: [], scope: scope, source: .japanese, target: .korean,
            mode: mode, enabled: true, autoStart: false, focusPage: 0
        )
        await controller.cacheTask?.value
        return controller
    }

    private func texts(_ controller: TranslationController, _ pages: [ComicPage]) -> [String?] {
        pages.map { controller.pages[$0.id]?.bubbles.first?.translation }
    }

    /// Everything on disk for the book is found, whatever else shares the
    /// folder; missing, unfinished and other books' entries are passed over.
    /// A fast job takes an accurate translation over its own.
    @Test(.enabled(if: TranslationMode.isFastAvailable))
    func everyFinishedEntryOnDiskIsLoadedAndNothingElse() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 7)
        func key(_ index: Int, _ mode: TranslationMode, to target: TranslationLanguage = .korean, scope: TranslationScope = .page) -> String {
            TranslationStore.key(pageID: pages[index].id, from: .japanese, to: target, scope: scope, mode: mode)
        }
        try store.save(page("A0"), key: key(0, .accurate))
        try store.save(page("F1"), key: key(1, .fast))
        try store.save(page("A2"), key: key(2, .accurate))
        try store.save(page("F2"), key: key(2, .fast))
        try store.save(page("A3", complete: false), key: key(3, .accurate))
        try store.save(page("F3"), key: key(3, .fast))
        // 4: nothing. 5: another language. 6: the other scope.
        try store.save(page("E5"), key: key(5, .accurate, to: .english))
        try store.save(page("S6"), key: key(6, .accurate, scope: .strip))
        // Whatever else is in the folder.
        try Data("x".utf8).write(to: store.root.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: store.root.appendingPathComponent(".DS_Store"))
        try Data("{}".utf8).write(to: store.root.appendingPathComponent("not-a-key.json"))

        let fast = await load(store, pages, mode: .fast)
        #expect(texts(fast, pages) == ["A0", "F1", "A2", "F3", nil, nil, nil])
        #expect(fast.completedPageIndices == [0, 1, 2, 3])
        #expect(fast.hasPages)

        let accurate = await load(store, pages, mode: .accurate)
        #expect(texts(accurate, pages) == ["A0", nil, "A2", nil, nil, nil, nil])
        #expect(accurate.completedPageIndices == [0, 2])

        let strip = await load(store, pages, mode: .accurate, scope: .strip)
        #expect(texts(strip, pages) == [nil, nil, nil, nil, nil, nil, "S6"])
    }

    /// The listing is the store's own names: what `save` writes, `existingKeys` lists.
    @Test func existingKeysAreExactlyTheSavedKeys() throws {
        let store = try makeTemporaryTranslationStore()
        let keys = (0..<20).map { TranslationStore.key(pageID: "page \($0)", from: .japanese, to: .korean, mode: $0.isMultiple(of: 2) ? .fast : .accurate) }
        for key in keys { try store.save(makeTranslatedPage(), key: key) }
        #expect(store.existingKeys() == Set(keys))
        store.remove(keys: Array(keys.prefix(5)))
        #expect(store.existingKeys() == Set(keys.dropFirst(5)))
    }
}

/// An AI chat reply lands as one batch of edits (`TranslationEdits.update(_:)`)
/// and is undone as one: the reader's edits afterwards are exactly what a
/// one-at-a-time update gives, undo puts back exactly what was there, and
/// what's saved matches.
@MainActor
struct AIChatBatchTests {
    private struct Setup {
        let vm: ReaderViewModel
        let pages: [ComicPage]
    }

    private func machinePage(_ index: Int) -> TranslatedPage {
        TranslatedPage(imageWidth: 1000, imageHeight: 1000, bubbles: (0..<3).map { number in
            TranslatedBubble(
                id: number, rect: CGRect(x: 100, y: 100 + Double(number) * 250, width: 300, height: 120), glyphSize: 30,
                isVertical: false, source: "原文\(index)-\(number)", translation: "기계 \(index)-\(number)", background: .white
            )
        })
    }

    private func open() async throws -> Setup {
        let vm = makeTestViewModel()
        vm.translationEnabled = true
        vm.translationTargetLanguage = .korean
        let pages = Fixture.makeImagePages(count: 3, title: "chat")
        for index in pages.indices {
            try vm.translation.store.save(machinePage(index), key: TranslationStore.key(pageID: pages[index].id, from: .japanese, to: .korean))
        }
        vm.currentSourceURL = URL(fileURLWithPath: "/books/chat")
        vm.source = ComicSource(title: "Chat", pages: pages)
        try await waitUntil { vm.translation.bookPageCount == 3 }
        vm.translation.setSource(.japanese)
        try await waitUntil { vm.translation.pages.count == 3 }
        await vm.translationEdits.load(pageIDs: pages.map(\.id), scope: .page)
        return Setup(vm: vm, pages: pages)
    }

    private func bubble(_ setup: Setup, _ page: Int, _ number: Int) -> TranslatedBubble {
        setup.vm.translation.pages[setup.pages[page].id]!.bubbles[number]
    }

    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func aReplyAcrossPagesIsTheSameAsOneByOneAndUndoesExactly() async throws {
        let setup = try await open()
        let vm = setup.vm
        let edits = vm.translationEdits
        // What the reader had done before asking the chat.
        edits.update(pageID: setup.pages[0].id, bubble: bubble(setup, 0, 0)) { $0.translations["ko"] = "내 번역" }
        edits.update(pageID: setup.pages[0].id, bubble: bubble(setup, 0, 1)) { $0.translations["en"] = "Mine" }
        edits.update(pageID: setup.pages[1].id, bubble: bubble(setup, 1, 0)) {
            $0.correctedSource = "修正"
            $0.retranslations["ko"] = "재번역"
        }
        edits.update(pageID: setup.pages[2].id, bubble: bubble(setup, 2, 2)) { $0.isHidden = true }
        edits.add(pageID: setup.pages[2].id, edit: {
            var added = BubbleEdit(recognizedSource: "足した", rect: CGRect(x: 600, y: 600, width: 100, height: 100), added: AddedBalloon(glyphSize: 20, isVertical: false, background: .white))
            added.retranslations["ko"] = "추가"
            return added
        }())
        let before = edits.pages

        let file = vm.aiChatFile(for: .book)
        // Everything shown: 3 + 3 + 2 of the page's own (one hidden) + the added one.
        #expect(file.balloons == 9)
        let reply = vm.aiChatLines.map { "[\($0.id)] 고침 \($0.id)" }.joined(separator: "\n")
        let lines = vm.aiChatLines

        // The same changes one by one, on a copy.
        var expected = before
        for line in lines {
            var page = expected[line.pageID] ?? PageEdits()
            page.update(line.bubble) { $0.translations["ko"] = "고침 \(line.id)" }
            expected[line.pageID] = page.isEmpty ? nil : page
        }

        let changes = vm.applyAIChatReply(reply)
        #expect(changes.updates.count == 9)
        #expect(edits.pages == expected)
        for line in lines {
            let shown = vm.aiChatLines(for: .book).first { $0.id == line.id }
            #expect(shown?.translation == "고침 \(line.id)")
        }
        // Saved as it is now.
        try await waitUntil { Self.saved(edits.store, setup.pages) == expected }

        vm.undoAIChatReply()
        #expect(edits.pages == before)
        #expect(vm.aiChatUndo == nil)
        try await waitUntil { Self.saved(edits.store, setup.pages) == before }
    }

    /// A batch with several changes to one balloon and to pages without edits
    /// yet ends where updating one at a time does — in memory and on disk.
    @Test func aRandomBatchEndsWhereOneByOneDoes() async throws {
        let pageIDs = ["p1", "p2", "p3", "p4"]
        let bubbles = (0..<4).map { index in
            TranslatedBubble(id: index, rect: CGRect(x: Double(index) * 200, y: 0, width: 100, height: 50), glyphSize: 20, isVertical: false, source: "原\(index)", translation: "기 \(index)", background: .white)
        }
        var random = TranslationTestRandom(seed: 0xBA7C4)
        for round in 0..<8 {
            let oneByOne = TranslationEdits(store: TranslationEditStore(root: try Fixture.makeTempDir()))
            let batched = TranslationEdits(store: TranslationEditStore(root: try Fixture.makeTempDir()))
            await oneByOne.load(pageIDs: pageIDs, scope: .page)
            await batched.load(pageIDs: pageIDs, scope: .page)
            // Some edits already there.
            for _ in 0..<3 {
                let pageID = pageIDs.randomElement(using: &random)!, bubble = bubbles.randomElement(using: &random)!
                for model in [oneByOne, batched] {
                    model.update(pageID: pageID, bubble: bubble) { $0.translations["en"] = "pre \(round)" }
                }
            }
            var updates: [(String, TranslatedBubble, String?, Bool)] = []
            for _ in 0..<Int.random(in: 1...12, using: &random) {
                updates.append((
                    pageIDs.randomElement(using: &random)!, bubbles.randomElement(using: &random)!,
                    Bool.random(using: &random) ? "새 \(Int.random(in: 0..<5, using: &random))" : nil,
                    Int.random(in: 0..<4, using: &random) == 0
                ))
            }
            func change(_ text: String?, _ hide: Bool) -> (inout BubbleEdit) -> Void {
                { edit in
                    edit.translations["ko"] = text
                    if hide { edit.isHidden.toggle() }
                }
            }
            for (pageID, bubble, text, hide) in updates {
                oneByOne.update(pageID: pageID, bubble: bubble, change(text, hide))
            }
            batched.update(updates.map { .init(pageID: $0.0, bubble: $0.1, change: change($0.2, $0.3)) })

            #expect(batched.pages == oneByOne.pages, "round \(round)")
            let expected = oneByOne.pages
            try await waitUntil { Self.saved(batched.store, pageIDs: pageIDs) == expected }
        }
    }

    // MARK: - On disk

    private static func saved(_ store: TranslationEditStore, _ pages: [ComicPage]) -> [String: PageEdits] {
        saved(store, pageIDs: pages.map(\.id))
    }

    private static func saved(_ store: TranslationEditStore, pageIDs: [String]) -> [String: PageEdits] {
        var found: [String: PageEdits] = [:]
        for id in pageIDs {
            if let edits = store.load(key: TranslationEditStore.key(pageID: id, scope: .page)) { found[id] = edits }
        }
        return found
    }
}
