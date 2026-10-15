import Foundation
import Testing
@testable import Panely

@MainActor
struct TranslationControllerTests {
    private func reload(
        _ controller: TranslationController,
        pages: [ComicPage],
        source: TranslationLanguage? = .japanese,
        target: TranslationLanguage = .korean,
        enabled: Bool = true
    ) {
        controller.reload(
            pages: pages, pageSizes: [], scope: .page, source: source, target: target,
            enabled: enabled, autoStart: false, focusPage: 0
        )
    }

    @Test func translationOrderStartsAtTheCurrentPageAndWraps() {
        #expect(TranslationController.translationOrder(count: 5, startingAt: 2) == [2, 3, 4, 0, 1])
        #expect(TranslationController.translationOrder(count: 3, startingAt: 9) == [2, 0, 1])
        #expect(TranslationController.translationOrder(count: 0, startingAt: 0).isEmpty)
    }

    @Test func reloadPicksUpCachedPages() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 3)
        try store.save(makeTranslatedPage("하나"), key: TranslationStore.key(pageID: pages[1].id, from: .japanese, to: .korean))
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore())

        reload(controller, pages: pages)
        try await waitUntil { !controller.pages.isEmpty }

        #expect(controller.pages.keys.sorted() == [pages[1].id])
        #expect(controller.pages[pages[1].id]?.bubbles.first?.translation == "하나")
        #expect(controller.completedPageIndices == [1])
        #expect(controller.completedPageCount == 1)
        #expect(controller.bookPageCount == 3)
    }

    @Test func otherPairsUnknownLanguageAndDisabledFeatureLoadNothing() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 1)
        try store.save(makeTranslatedPage(), key: TranslationStore.key(pageID: pages[0].id, from: .japanese, to: .korean))
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore())

        reload(controller, pages: pages, target: .english)
        await controller.cacheTask?.value
        #expect(controller.pages.isEmpty)

        reload(controller, pages: pages, source: nil)
        await controller.cacheTask?.value
        #expect(controller.pages.isEmpty)

        reload(controller, pages: pages, enabled: false)
        await controller.cacheTask?.value
        #expect(controller.pages.isEmpty)
        #expect(controller.bookPageCount == 0)
    }

    @Test func clearCacheEmptiesStoreAndOpenBook() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 1)
        try store.save(makeTranslatedPage(), key: TranslationStore.key(pageID: pages[0].id, from: .japanese, to: .korean))
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore())
        reload(controller, pages: pages)
        try await waitUntil { !controller.pages.isEmpty }

        let removed = await controller.clearCache()

        #expect(removed > 0)
        #expect(controller.pages.isEmpty)
        #expect(controller.completedPageIndices.isEmpty)
        #expect(store.sizeBytes() == 0)
    }

    @Test func startOnAFullyTranslatedBookDoesNothing() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 1)
        try store.save(makeTranslatedPage(), key: TranslationStore.key(pageID: pages[0].id, from: .japanese, to: .korean))
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore())
        reload(controller, pages: pages)
        try await waitUntil { controller.completedPageCount == 1 }

        controller.start()

        #expect(controller.phase == .idle)
        #expect(!controller.isWorking)
    }

    @Test func firstRunFlagIsPerBuild() {
        let defaults = InMemoryKeyValueStore()
        #expect(TranslationController(store: TranslationStore(root: FileManager.default.temporaryDirectory), defaults: defaults).isFirstRunForThisBuild)
        defaults.set(TranslationController.buildIdentifier, forKey: TranslationController.warmedUpBuildKey)
        #expect(!TranslationController(store: TranslationStore(root: FileManager.default.temporaryDirectory), defaults: defaults).isFirstRunForThisBuild)
    }
}

@MainActor
struct ReaderViewModelTranslationTests {
    @Test func featureIsOffByDefault() {
        let vm = makeTestViewModel()
        #expect(vm.translationEnabled == false)
        #expect(vm.translationFeatureAvailable == false)
        #expect(vm.translationOverlayPages.isEmpty)
        #expect(vm.translatedPageIndices.isEmpty)
        #expect(vm.toolbarState().translation == nil)
        #expect(vm.translationMode == .fast)
    }

    @Test func globalSettingsPersist() {
        let defaults = InMemoryKeyValueStore()
        let vm = makeTestViewModel(keyValueStore: defaults)
        vm.translationEnabled = true
        vm.translationTargetLanguage = .english
        vm.translationMode = .accurate

        let reloaded = makeTestViewModel(keyValueStore: defaults)
        #expect(reloaded.translationEnabled)
        #expect(reloaded.translationTargetLanguage == .english)
        #expect(reloaded.translationMode == .accurate)
    }

    @Test func targetFollowsTheInterfaceLanguageUntilChosen() {
        let vm = makeTestViewModel()
        vm.appLanguage = .korean
        #expect(vm.translationTargetLanguage == .korean)
        vm.appLanguage = .english
        #expect(vm.translationTargetLanguage == .english)

        vm.translationTargetLanguage = .korean
        vm.appLanguage = .english
        #expect(vm.translationTargetLanguage == .korean)
    }

    @Test func bookLanguageAndAutoTranslateArePerSeries() {
        let store = ReaderSeriesPreferencesStore(defaults: InMemoryKeyValueStore())
        store.setTranslationSource(.chineseTraditional, forSeries: "series:/a")
        store.setAutoTranslate(true, forSeries: "series:/a")

        #expect(store.translationSource(forSeries: "series:/a") == .chineseTraditional)
        #expect(store.autoTranslate(forSeries: "series:/a"))
        #expect(store.translationSource(forSeries: "series:/b") == nil)
        #expect(store.autoTranslate(forSeries: "series:/b") == false)
    }

    @Test func scopeFollowsTheLayout() {
        let vm = makeTestViewModel()
        vm.layout = .single
        #expect(vm.translationScope == .page)
        vm.layout = .vertical
        #expect(vm.translationScope == .strip)
    }

    /// Clearing the cache leaves the shown language with nothing in it;
    /// picking it in the panel then has to translate, not just turn on a
    /// translation that isn't there.
    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func aLanguageEmptiedByClearingTheCacheIsTranslatedWhenPicked() async throws {
        let vm = makeTestViewModel()
        vm.translationEnabled = true
        vm.translationTargetLanguage = .korean
        let pages = Fixture.makeImagePages(count: 2)
        try vm.translation.store.save(
            makeTranslatedPage("하나"),
            key: TranslationStore.key(pageID: pages[0].id, from: .japanese, to: .korean)
        )
        vm.currentSourceURL = URL(fileURLWithPath: "/books/test")
        vm.source = ComicSource(title: "Test", pages: pages)
        try await waitUntil { vm.translation.bookPageCount == 2 }
        vm.translation.setSource(.japanese)
        try await waitUntil { !vm.translation.pages.isEmpty }
        #expect(!vm.translationNeedsStarting(vm.translation))
        #expect(vm.translationIsShowing)

        _ = await vm.translationManager.clearCache()

        #expect(vm.translation.pages.isEmpty)
        #expect(vm.translationNeedsStarting(vm.translation))
        #expect(!vm.translationIsShowing)
        // Still offered — as a language to translate into, first in the menu.
        #expect(vm.toolbarState().translation?.suggestedLanguage?.language == .korean)
    }

    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func overlayPagesFollowTheImagesOnScreen() async throws {
        let vm = makeTestViewModel()
        vm.translationEnabled = true
        vm.translationTargetLanguage = .korean
        vm.layout = .double
        let pages = Fixture.makeImagePages(count: 4)
        // No series for a bare source, so the language comes from the
        // controller: give it the language and a cached translation for page 3.
        try vm.translation.store.save(
            makeTranslatedPage("셋"),
            key: TranslationStore.key(pageID: pages[3].id, from: .japanese, to: .korean)
        )

        // A real load sets the book's URL alongside its pages; jobs are keyed by it.
        vm.currentSourceURL = URL(fileURLWithPath: "/books/test")
        vm.source = ComicSource(title: "Test", pages: pages)
        try await waitUntil { vm.translation.bookPageCount == 4 }
        vm.translation.setSource(.japanese)
        try await waitUntil { !vm.translation.pages.isEmpty }

        vm.currentPageIndex = 2
        await vm.refreshImages()

        // Spread (2, 3): no translation for 2, one for 3 — in image order.
        let overlays = vm.translationOverlayPages
        #expect(overlays.count == vm.currentImages.count)
        #expect(overlays.count == 2)
        #expect(overlays[0] == nil)
        #expect(overlays[1]?.bubbles.first?.translation == "셋")
        #expect(vm.translatedPageIndices == [3])
        #expect(vm.toolbarState().translation?.hasTranslations == true)
        #expect(vm.toolbarState().translation?.showsTranslation == true)
        #expect(vm.toolbarState().translation?.languages.map(\.language) == [.korean])
    }

    /// The series remembers its language, but a volume with nothing of it
    /// translated mustn't show that language as selected or switchable —
    /// only as one to start.
    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func languageWithNothingTranslatedIsOnlyOfferedToStart() async throws {
        let vm = makeTestViewModel()
        vm.translationEnabled = true
        vm.translationTargetLanguage = .korean
        let pages = Fixture.makeImagePages(count: 2)
        vm.currentSourceURL = URL(fileURLWithPath: "/books/volume-2")
        vm.source = ComicSource(title: "Volume 2", pages: pages)
        try await waitUntil { vm.translation.bookPageCount == 2 }
        vm.translation.setSource(.japanese)

        #expect(vm.translationOverlayVisible)
        #expect(!vm.translationIsShowing)
        let toolbar = try #require(vm.toolbarState().translation)
        #expect(!toolbar.showsTranslation)
        #expect(toolbar.languages.isEmpty)
        // The series' language comes first, as "translate this book into it".
        #expect(toolbar.suggestedLanguage?.language == .korean)
        #expect(!toolbar.otherLanguages.map(\.language).contains(.korean))
        #expect(!toolbar.otherLanguages.map(\.language).contains(.japanese)) // the book's own
    }

    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func toggleOverlayFlipsVisibility() {
        let vm = makeTestViewModel()
        vm.translationEnabled = true
        let before = vm.translationOverlayVisible
        vm.toggleTranslationOverlay()
        #expect(vm.translationOverlayVisible == !before)
    }

    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func switchingBooksDropsTheOldBooksTranslationsAtOnce() async throws {
        let vm = makeTestViewModel()
        vm.translationEnabled = true
        let first = Fixture.makeImagePages(count: 1)
        try vm.translation.store.save(
            makeTranslatedPage(),
            key: TranslationStore.key(pageID: first[0].id, from: .japanese, to: vm.translationTargetLanguage)
        )
        vm.currentSourceURL = URL(fileURLWithPath: "/books/one")
        vm.source = ComicSource(title: "One", pages: first)
        try await waitUntil { vm.translation.bookPageCount == 1 }
        vm.translation.setSource(.japanese)
        try await waitUntil { !vm.translation.pages.isEmpty }

        vm.currentSourceURL = URL(fileURLWithPath: "/books/two")
        vm.source = ComicSource(title: "Two", pages: Fixture.makeImagePages(count: 2, title: "q"))

        #expect(vm.translation.pages.isEmpty)
    }
}

@MainActor
struct ReaderViewModelTranslationLanguageTests {
    @Test func shownLanguageDefaultsToTheDefaultAndIsRememberedPerSeries() {
        let vm = makeTestViewModel()
        vm.translationEnabled = true
        vm.translationTargetLanguage = .korean
        vm.currentSourceURL = URL(fileURLWithPath: "/series/a/vol1.cbz")
        #expect(vm.translationDisplayLanguage == .korean)

        vm.translationDisplayLanguage = .english

        #expect(vm.translationDisplayLanguage == .english)
        // Another series still uses the default.
        vm.currentSourceURL = URL(fileURLWithPath: "/series/b/vol1.cbz")
        #expect(vm.translationDisplayLanguage == .korean)
        // Back in the first series, its choice is still there.
        vm.currentSourceURL = URL(fileURLWithPath: "/series/a/vol2.cbz")
        #expect(vm.translationDisplayLanguage == .english)
    }

    @Test func systemDefaultFollowsTheInterfaceLanguage() {
        let vm = makeTestViewModel()
        vm.translationTargetLanguage = .english
        vm.translationTargetChoice = nil
        vm.appLanguage = .korean
        #expect(vm.translationTargetLanguage == .korean)
    }

    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func originalAndLanguagesToggle() {
        let vm = makeTestViewModel()
        vm.translationEnabled = true
        vm.showTranslation(in: .english)
        #expect(vm.translationOverlayVisible)
        vm.showOriginal()
        #expect(!vm.translationOverlayVisible)
        vm.toggleTranslationOverlay()
        #expect(vm.translationOverlayVisible)
    }

    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func eachLanguageKeepsItsOwnResultsAndTheShownOneCarriesTheOthers() async throws {
        let vm = makeTestViewModel()
        vm.translationEnabled = true
        vm.translationTargetLanguage = .korean
        vm.layout = .single
        let pages = Fixture.makeImagePages(count: 2)
        let source = TranslationLanguage.japanese
        try vm.translation.store.save(makeTranslatedPage("하나"), key: TranslationStore.key(pageID: pages[0].id, from: source, to: .korean))
        try vm.translation.store.save(makeTranslatedPage("One"), key: TranslationStore.key(pageID: pages[0].id, from: source, to: .english))

        vm.currentSourceURL = URL(fileURLWithPath: "/series/a/vol1.cbz")
        vm.translationSourceLanguage = source
        vm.source = ComicSource(title: "Vol 1", pages: pages)
        try await waitUntil { vm.translationLanguagesForBook.count == 2 }

        // Both languages are listed, the shown one first, each with its own count.
        #expect(vm.translationLanguagesForBook.map(\.target) == [.korean, .english])
        #expect(vm.translationLanguagesForBook.allSatisfy { $0.completedPageCount == 1 })

        vm.currentPageIndex = 0
        await vm.refreshImages()
        let shown = try #require(vm.translationOverlayPages.first ?? nil)
        #expect(shown.bubbles.first?.translation == "하나")
        #expect(shown.bubbles.first?.alternates?[.english] == "One")

        vm.showTranslation(in: .english)
        #expect(vm.translationOverlayPages.first??.bubbles.first?.translation == "One")
    }
}
