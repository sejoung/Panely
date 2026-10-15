import CoreGraphics
import Foundation
import Observation
import Testing
@testable import Panely

/// `translationOverlayPages` keeps each page it builds (`TranslationMemo`)
/// until something it's made of changes. These drive a real view model
/// through everything that can change a page — balloons arriving and
/// changing, the reader's edits, edit mode, retranslations in flight, other
/// languages gaining and losing pages, switching language and book — and
/// after every step compare what it returns with the same pages built from
/// scratch the way they were before the memo existed.
@MainActor
@Suite(.serialized)
struct TranslationOverlayMemoTests {
    nonisolated private static let languages: [TranslationLanguage] = [.korean, .english, .chineseSimplified, .chineseTraditional]

    // MARK: - Setup

    private struct Book {
        let url: URL
        let pages: [ComicPage]
    }

    /// Speech levels are matched (`GatedSpeechLevelCorrector`) into
    /// `matching` — any pair, so other languages' pages change too.
    private func makeViewModel(gate: TranslationPermitGate, matching: Set<TranslationLanguage> = Set(languages)) -> ReaderViewModel {
        let vm = ReaderViewModel(dependencies: makeTestDependencies(
            makeSpeechLevelCorrector: { _, target in matching.contains(target) ? GatedSpeechLevelCorrector(gate: gate) : nil }
        ))
        vm.translationEnabled = true
        vm.translationTargetLanguage = .korean
        vm.layout = .double
        return vm
    }

    private func save(_ vm: ReaderViewModel, _ book: Book, pages indices: some Sequence<Int>, into target: TranslationLanguage, label: String, bubbles: Int = 3) throws {
        for index in indices {
            try vm.translationManager.store.save(
                makeTranslationTestPage(pageIndex: index, bubbles: bubbles, label: label),
                key: TranslationStore.key(pageID: book.pages[index].id, from: .japanese, to: target)
            )
        }
    }

    /// Open `book` the way a load does, and wait for every language's cache.
    private func open(_ vm: ReaderViewModel, _ book: Book) async throws {
        vm.currentSourceURL = book.url
        vm.translationSourceLanguage = .japanese
        vm.source = ComicSource(title: book.url.deletingPathExtension().lastPathComponent, pages: book.pages)
        // The old book's pages go at once; the new one isn't set up yet.
        check(vm, "opening \(book.url.lastPathComponent), before it's set up")
        try await waitUntil {
            vm.translation.bookPageCount == book.pages.count
                && Set(vm.translationManager.openBook.filter(\.isConfigured).map(\.target)) == Set(Self.languages)
        }
        for controller in vm.translationManager.openBook {
            await controller.cacheTask?.value
            // Translating a page again asks for a job; there's none here.
            controller.requestStart = {}
        }
        await vm.refreshImages()
    }

    // MARK: - The reference

    /// The overlay pages as built before the memo: from scratch, each other
    /// language's balloon found by its text.
    private func reference(_ vm: ReaderViewModel) -> [TranslatedPage?] {
        guard vm.translationFeatureAvailable else { return [] }
        let shown = vm.translation
        let others = vm.translationManager.openBook.filter { $0 !== shown && !$0.pages.isEmpty }
        return vm.imageLoader.currentPageIDs.map { id in
            guard let machine = shown.pages[id] else { return nil }
            var page = vm.translationEdits.apply(to: machine, pageID: id, target: shown.target, includeHidden: vm.isEditingTranslations)
            page.pageID = id
            guard !others.isEmpty else { return page }
            let edits = vm.translationEdits.edits(forPage: id)
            for index in page.bubbles.indices {
                var alternates: [TranslationLanguage: String] = [:]
                for other in others {
                    guard let bubble = other.pages[id]?.bubbles.first(where: { $0.source == page.bubbles[index].source }) else { continue }
                    if let text = edits?.translation(of: bubble, in: other.target) ?? bubble.translation, !text.isEmpty {
                        alternates[other.target] = text
                    }
                }
                page.bubbles[index].alternates = alternates.isEmpty ? nil : alternates
            }
            return page
        }
    }

    /// What's shown now equals the reference — read twice (the second from
    /// the memo) and once more with the memo emptied. The memo is put back
    /// afterwards, so the check itself doesn't change what's kept.
    @discardableResult
    private func check(_ vm: ReaderViewModel, _ step: String) -> Bool {
        let expected = reference(vm)
        let first = vm.translationOverlayPages
        let second = vm.translationOverlayPages
        let kept = vm.translationMemo
        vm.translationMemo = .init()
        let fresh = vm.translationOverlayPages
        vm.translationMemo = kept
        guard first == expected, second == expected, fresh == expected else {
            Issue.record("Overlay pages differ from a fresh build after \(step)")
            return false
        }
        return true
    }

    private func revisionSignature(_ vm: ReaderViewModel) -> [Int] {
        vm.translationManager.openBook.flatMap { $0.pageRevisions.values }.sorted()
    }

    /// Give background work (speech levels matched page by page) a moment
    /// to land, without failing if it has nothing to do.
    private func settle(_ vm: ReaderViewModel, changingFrom signature: [Int]) async {
        let deadline = ContinuousClock.now + .milliseconds(300)
        while revisionSignature(vm) == signature, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Random edits

    /// Mostly the pages on screen — where a stale page would show.
    private func somePageIDs(_ vm: ReaderViewModel, _ book: Book, using random: inout TranslationTestRandom) -> [String] {
        Int.random(in: 0..<4, using: &random) == 0 ? book.pages.map(\.id) : vm.imageLoader.currentPageIDs
    }

    private func anyMachineBubble(_ vm: ReaderViewModel, _ book: Book, using random: inout TranslationTestRandom) -> (String, TranslatedBubble)? {
        let candidates = somePageIDs(vm, book, using: &random).flatMap { id in
            vm.translationManager.openBook.compactMap { $0.pages[id] }.flatMap { $0.bubbles }.map { (id, $0) }
        }
        return candidates.randomElement(using: &random)
    }

    private func anyEdit(_ vm: ReaderViewModel, _ book: Book, where condition: (BubbleEdit) -> Bool, using random: inout TranslationTestRandom) -> (String, BubbleEdit)? {
        let pageIDs = Set(somePageIDs(vm, book, using: &random))
        return vm.translationEdits.pages.sorted { $0.key < $1.key }
            .filter { pageIDs.contains($0.key) }
            .flatMap { pageID, edits in edits.bubbles.filter(condition).map { (pageID, $0) } }
            .randomElement(using: &random)
    }

    private func standIn(for edit: BubbleEdit) -> TranslatedBubble {
        TranslatedBubble(id: 0, rect: edit.rect, glyphSize: 30, isVertical: true, source: edit.recognizedSource, translation: nil, background: .white)
    }

    // MARK: - Tests

    @Test(.enabled(if: TranslationController.isSupportedOnThisMac), arguments: [UInt64(1)])
    func overlayPagesEqualAFreshBuildThroughEveryChange(seed: UInt64) async throws {
        let gate = TranslationPermitGate()
        let vm = makeViewModel(gate: gate)
        let books = [
            Book(url: URL(fileURLWithPath: "/series/memo/vol1.cbz"), pages: Fixture.makeImagePages(count: 6, title: "a")),
            Book(url: URL(fileURLWithPath: "/series/memo/vol2.cbz"), pages: Fixture.makeImagePages(count: 4, title: "b")),
        ]
        for book in books {
            try save(vm, book, pages: [0, 1, 2, 3], into: .korean, label: "한국어")
            try save(vm, book, pages: [1, 2, 3], into: .english, label: "English")
            try save(vm, book, pages: [2], into: .chineseSimplified, label: "中文", bubbles: 2)
        }
        var bookIndex = 0
        try await open(vm, books[bookIndex])
        #expect(vm.translation.hasPages)
        check(vm, "opening")

        var random = TranslationTestRandom(seed: seed)
        var memoHits = 0
        for step in 0..<70 {
            let book = books[bookIndex]
            let target = Self.languages.randomElement(using: &random)!
            let operation = Int.random(in: 0..<20, using: &random)
            let description: String
            switch operation {
            case 0, 1:
                let index = Int.random(in: 0..<book.pages.count, using: &random)
                vm.currentPageIndex = index
                await vm.refreshImages()
                description = "turning to page \(index)"
            case 2, 3:
                guard let (pageID, bubble) = anyMachineBubble(vm, book, using: &random) else { continue }
                let text: String? = Bool.random(using: &random) ? "내 번역 \(step)" : nil
                vm.translationEdits.update(pageID: pageID, bubble: bubble) { $0.translations[target.rawValue] = text }
                description = "the reader's \(target.rawValue) translation \(text ?? "removed")"
            case 4:
                guard let (pageID, bubble) = anyMachineBubble(vm, book, using: &random) else { continue }
                vm.translationEdits.hide(pageID: pageID, bubble: bubble)
                description = "hiding a balloon"
            case 5:
                guard let (pageID, edit) = anyEdit(vm, book, where: \.isHidden, using: &random) else { continue }
                vm.translationEdits.showHidden(pageID: pageID, edit: edit)
                description = "showing a hidden balloon"
            case 6:
                guard let (pageID, bubble) = anyMachineBubble(vm, book, using: &random) else { continue }
                let corrected: String? = Int.random(in: 0..<3, using: &random) > 0 ? "修正\(step)" : nil
                vm.translationEdits.update(pageID: pageID, bubble: bubble) {
                    $0.correctedSource = corrected
                    $0.retranslations = [:]
                }
                description = "correcting an original"
            case 7:
                guard let (pageID, edit) = anyEdit(vm, book, where: { $0.sourceToTranslate != nil }, using: &random) else { continue }
                // Into the shown language mostly: that's where it shows as pending.
                let into = Bool.random(using: &random) ? vm.translation.target : target
                vm.translationEdits.beginRetranslation(.init(pageID: pageID, recognizedSource: edit.recognizedSource, correctedSource: edit.sourceToTranslate!, target: into))
                description = "a retranslation starting"
            case 8:
                guard let retranslation = vm.translationEdits.retranslating.sorted(by: { "\($0)" < "\($1)" }).randomElement(using: &random),
                      let edit = vm.translationEdits.edits(forPage: retranslation.pageID)?.bubbles.first(where: { $0.recognizedSource == retranslation.recognizedSource })
                else { continue }
                let text: String? = Bool.random(using: &random) ? "再翻訳\(step)" : nil
                vm.translationEdits.finishRetranslation(retranslation, bubble: standIn(for: edit), text: text)
                description = "a retranslation finishing"
            case 9:
                let pageID = book.pages.randomElement(using: &random)!.id
                var edit = BubbleEdit(
                    recognizedSource: Bool.random(using: &random) ? "足した\(step)" : "",
                    rect: CGRect(x: Double.random(in: 0...800, using: &random), y: Double.random(in: 0...1200, using: &random), width: 80, height: 90),
                    added: AddedBalloon(glyphSize: 20, isVertical: false, background: .white)
                )
                if Bool.random(using: &random) { edit.retranslations[target.rawValue] = "추가 \(step)" }
                vm.translationEdits.add(pageID: pageID, edit: edit)
                description = "adding a balloon"
            case 10:
                guard let (pageID, edit) = anyEdit(vm, book, where: { $0.added != nil }, using: &random) else { continue }
                vm.translationEdits.remove(pageID: pageID, source: edit.recognizedSource, rect: edit.rect)
                description = "removing an added balloon"
            case 11:
                vm.isEditingTranslations.toggle()
                description = "edit mode \(vm.isEditingTranslations ? "on" : "off")"
            case 12:
                vm.showTranslation(in: target)
                description = "showing \(target.rawValue)"
            case 13:
                let controllers = vm.translationManager.openBook.filter(\.hasPages)
                guard let controller = controllers.randomElement(using: &random),
                      let index = book.pages.indices.filter({ controller.pages[book.pages[$0].id] != nil }).randomElement(using: &random)
                else { continue }
                await controller.translateAgain(pageIndices: [index])
                description = "\(controller.target.rawValue) losing page \(index)"
            case 14:
                guard let controller = vm.translationManager.openBook.first(where: { $0.target == target }) else { continue }
                let indices = book.pages.indices.filter { _ in Bool.random(using: &random) }
                try save(vm, book, pages: indices, into: target, label: "\(target.rawValue) v\(step)\(step.isMultiple(of: 3) ? "!" : "")", bubbles: Int.random(in: 1...3, using: &random))
                vm.setUp(controller, target: target, autoStart: false, restart: false)
                check(vm, "\(target.rawValue) reloading, before its cache")
                await controller.cacheTask?.value
                description = "\(target.rawValue) gaining pages \(indices)"
            case 15:
                let signature = revisionSignature(vm)
                await gate.release(Int.random(in: 1...3, using: &random))
                await settle(vm, changingFrom: signature)
                description = "speech levels matched"
            case 16:
                vm.translationMatchesSpeechLevel.toggle()
                check(vm, "speech-level matching switched, before the caches")
                for controller in vm.translationManager.openBook { await controller.cacheTask?.value }
                description = "speech-level matching \(vm.translationMatchesSpeechLevel ? "on" : "off")"
            case 17:
                var updates: [TranslationEdits.BubbleUpdate] = []
                for _ in 0..<Int.random(in: 1...5, using: &random) {
                    guard let (pageID, bubble) = anyMachineBubble(vm, book, using: &random) else { break }
                    let text = "일괄 \(step)"
                    updates.append(.init(pageID: pageID, bubble: bubble) { $0.translations[target.rawValue] = text })
                }
                vm.translationEdits.update(updates)
                description = "a batch of \(updates.count) edits"
            case 18:
                if Bool.random(using: &random) { vm.translationEdits.showAllHidden() } else { vm.translationEdits.revertAllInBook() }
                description = "showing all / reverting the book"
            default:
                bookIndex = 1 - bookIndex
                vm.currentPageIndex = 0
                try await open(vm, books[bookIndex])
                description = "switching to book \(bookIndex + 1)"
            }
            if !vm.translationMemo.overlayPages.isEmpty { memoHits += 1 }
            guard check(vm, "step \(step): \(description) (seed \(seed))") else { break }
        }
        // The memo was in play, not rebuilt from empty every time.
        #expect(memoHits > 25)
        await gate.open()
    }

    /// The overlay is read inside the viewer's observation; a page served
    /// from the memo must still have registered everything it's made of, or
    /// the viewer stops updating.
    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func overlayPagesFromTheMemoStillNotifyOfEveryChange() async throws {
        let gate = TranslationPermitGate()
        // Only the shown language's pages change in place, from the page on screen.
        let vm = makeViewModel(gate: gate, matching: [.korean])
        let book = Book(url: URL(fileURLWithPath: "/series/observe/vol1.cbz"), pages: Fixture.makeImagePages(count: 4, title: "o"))
        try save(vm, book, pages: [0, 1, 2, 3], into: .korean, label: "한국어", bubbles: 1)
        try save(vm, book, pages: [0, 1], into: .english, label: "English", bubbles: 1)
        try await open(vm, book)
        await vm.translationEdits.load(pageIDs: book.pages.map(\.id), scope: .page)
        vm.translationMatchesSpeechLevel = true
        for controller in vm.translationManager.openBook { await controller.cacheTask?.value }
        let korean = try #require(vm.translationManager.openBook.first { $0.target == .korean })
        let english = try #require(vm.translationManager.openBook.first { $0.target == .english })
        let bubble = try #require(korean.pages[book.pages[0].id]?.bubbles.first)

        func expectNotified(_ what: String, _ change: () async throws -> Void) async throws {
            _ = vm.translationOverlayPages
            _ = vm.translationOverlayPages // now from the memo
            let probe = ObservationProbe { _ = vm.translationOverlayPages }
            try await change()
            #expect(probe.fired, "\(what)")
            check(vm, what)
        }

        try await expectNotified("a balloon's speech level matched") {
            let before = korean.pages[book.pages[0].id]
            await gate.release(1)
            try await waitUntil { korean.pages[book.pages[0].id] != before }
        }
        try await expectNotified("the reader's translation") {
            vm.translationEdits.update(pageID: book.pages[0].id, bubble: bubble) { $0.translations["ko"] = "내 번역" }
        }
        try await expectNotified("hiding") { vm.translationEdits.hide(pageID: book.pages[0].id, bubble: bubble) }
        try await expectNotified("edit mode") { vm.isEditingTranslations = true }
        try await expectNotified("a correction") {
            vm.translationEdits.update(pageID: book.pages[0].id, bubble: bubble) {
                $0.isHidden = false
                $0.translations["ko"] = nil
                $0.correctedSource = "修正"
            }
        }
        let retranslation = TranslationEdits.Retranslation(pageID: book.pages[0].id, recognizedSource: bubble.source, correctedSource: "修正", target: .korean)
        try await expectNotified("a retranslation starting") { vm.translationEdits.beginRetranslation(retranslation) }
        #expect(vm.translationOverlayPages.first??.bubbles.first?.translation == nil, "shown as pending")
        try await expectNotified("a retranslation finishing") {
            vm.translationEdits.finishRetranslation(retranslation, bubble: bubble, text: "재번역")
        }
        #expect(vm.translationOverlayPages.first??.bubbles.first?.translation == "재번역")
        try await expectNotified("another language losing a page") { await english.translateAgain(pageIndices: [0]) }
        try await expectNotified("another language losing its last page") { await english.translateAgain(pageIndices: [1]) }
        try await expectNotified("another language gaining pages") {
            try save(vm, book, pages: [0], into: .english, label: "Again", bubbles: 1)
            vm.setUp(english, target: .english, autoStart: false, restart: false)
            await english.cacheTask?.value
        }
        try await expectNotified("switching language") { vm.showTranslation(in: .english) }
        try await expectNotified("turning the page") {
            vm.currentPageIndex = 2
            await vm.refreshImages()
        }
        await gate.open()
    }

    /// What only asks whether there's anything to show (toolbar, menus,
    /// edit bar) reads `hasPages`, and so doesn't re-render as a page fills in.
    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func whetherThereIsATranslationDoesNotNotifyAsAPageChanges() async throws {
        let gate = TranslationPermitGate()
        let vm = makeViewModel(gate: gate)
        let book = Book(url: URL(fileURLWithPath: "/series/flag/vol1.cbz"), pages: Fixture.makeImagePages(count: 2, title: "f"))
        try save(vm, book, pages: [0, 1], into: .korean, label: "한국어", bubbles: 1)
        try save(vm, book, pages: [0], into: .english, label: "English", bubbles: 1)
        try await open(vm, book)
        vm.translationMatchesSpeechLevel = true
        for controller in vm.translationManager.openBook { await controller.cacheTask?.value }
        #expect(vm.translationIsShowing && vm.canEditTranslations && vm.canTranslateAgain)

        let probe = ObservationProbe {
            _ = vm.translationIsShowing
            _ = vm.canEditTranslations
            _ = vm.canTranslateAgain
            _ = vm.translationLanguagesWithResults
            _ = vm.translationLanguagesForBook.map(vm.translationNeedsStarting)
        }
        let pages = ObservationProbe { _ = vm.translationManager.openBook.map(\.pages) }
        let signature = revisionSignature(vm)
        await gate.release(2)
        try await waitUntil { revisionSignature(vm) != signature }
        #expect(pages.fired)
        #expect(!probe.fired)

        // …but does when the shown language empties.
        let emptied = ObservationProbe { _ = vm.translationIsShowing }
        await vm.translation.translateAgain(pageIndices: [0, 1])
        #expect(!vm.translationIsShowing)
        #expect(emptied.fired)
        await gate.open()
    }

    /// The panel's hidden-balloon list keeps the book's page indices until
    /// the book changes; the next book's balloons are listed at its own.
    @Test func hiddenBalloonsAreListedAtTheOpenBooksPages() async throws {
        let vm = makeTestViewModel()
        let first = Fixture.makeImagePages(count: 3, title: "h")
        let second = Fixture.makeImagePages(count: 3, title: "k")
        let bubble = makeTranslationTestPage(pageIndex: 0, bubbles: 1, label: "x").bubbles[0]

        vm.source = ComicSource(title: "One", pages: first)
        await vm.translationEdits.load(pageIDs: first.map(\.id), scope: .page)
        vm.translationEdits.hide(pageID: first[2].id, bubble: bubble)
        #expect(vm.translationHiddenBalloons.map(\.pageIndex) == [2])

        vm.source = ComicSource(title: "Two", pages: second.reversed())
        await vm.translationEdits.load(pageIDs: second.map(\.id), scope: .page)
        vm.translationEdits.hide(pageID: second[2].id, bubble: bubble)
        vm.translationEdits.hide(pageID: second[0].id, bubble: bubble)
        // Reversed: second[2] is page 0 of this book, second[0] page 2.
        #expect(vm.translationHiddenBalloons.map(\.pageIndex) == [0, 2])
        #expect(vm.translationHiddenBalloons.map(\.pageID) == [second[2].id, second[0].id])
    }

    /// The series' other volumes are kept while the book and its folder are
    /// the same, and worked out again when either changes.
    @Test func seriesVolumesFollowTheBookAndItsFolder() {
        let vm = makeTestViewModel()
        let folder = URL(fileURLWithPath: "/Comics")
        let one = folder.appendingPathComponent("One Piece v01.cbz")
        let two = folder.appendingPathComponent("One Piece v02.cbz")
        let other = folder.appendingPathComponent("Berserk v01.cbz")
        let otherTwo = folder.appendingPathComponent("Berserk v02.cbz")
        vm.currentSourceURL = one
        vm.siblings = [one, two, other]
        #expect(vm.translatableSeriesVolumes == [two])
        #expect(vm.translatableSeriesVolumes == [two])

        let three = folder.appendingPathComponent("One Piece v03.cbz")
        vm.siblings = [one, two, three, other, otherTwo]
        #expect(vm.translatableSeriesVolumes == [two, three])

        vm.currentSourceURL = other
        #expect(vm.translatableSeriesVolumes == [otherTwo])

        vm.currentSourceURL = nil
        #expect(vm.translatableSeriesVolumes.isEmpty)
    }
}
