import Testing
import Foundation
@testable import Panely

/// Picking a language switches Panely's UI on the spot without reopening
/// the app or the current book.
@MainActor
struct ReaderViewModelAppLanguageTests {

    @Test func pickingALanguageSwitchesTheUIImmediately() {
        let vm = makeTestViewModel()
        #expect(vm.localization.language == "en")

        vm.appLanguage = .korean

        #expect(vm.localization.language == "ko")
        #expect(String(localized: "Bookmarks", bundle: vm.localization.bundle) == "북마크")
        #expect(vm.localization.locale.identifier == "ko")

        vm.appLanguage = .english

        #expect(String(localized: "Bookmarks", bundle: vm.localization.bundle) == "Bookmarks")
    }

    @Test func savedChoiceIsAppliedAtLaunch() {
        let defaults = InMemoryKeyValueStore([
            ReaderPreferences.appLanguageKey: AppLanguage.korean.rawValue,
        ])
        let vm = makeTestViewModel(keyValueStore: defaults)

        #expect(vm.appLanguage == .korean)
        #expect(vm.localization.language == "ko")
    }

    @Test func switchingLanguageLeavesOtherInstancesAlone() {
        let korean = makeTestViewModel()
        let english = makeTestViewModel()

        korean.appLanguage = .korean

        #expect(english.localization.language == "en")
    }

    @Test func switchingLanguagePreservesTheOpenBookAndPage() {
        let vm = makeTestViewModel()
        let book = URL(fileURLWithPath: "/lib/Series/Vol02.cbz")
        vm.currentSourceURL = book
        vm.openedSourceURL = URL(fileURLWithPath: "/lib", isDirectory: true)
        vm.currentPageIndex = 12

        vm.appLanguage = .korean
        vm.appLanguage = .english

        #expect(vm.currentSourceURL == book)
        #expect(vm.openedSourceURL == URL(fileURLWithPath: "/lib", isDirectory: true))
        #expect(vm.currentPageIndex == 12)
    }
}
