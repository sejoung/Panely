import Testing
import Foundation
@testable import Panely

/// Picking a language switches Panely's own UI on the spot; AppKit's menu
/// items keep the launch language until a restart, which Settings offers.
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

    @Test func restartOnlyOfferedWhileAppKitIsInAnotherLanguage() {
        // The test host launches in English (the scheme's language).
        let vm = makeTestViewModel()
        #expect(vm.launchUILanguage == "en")
        #expect(vm.appLanguageNeedsRestart == false)

        vm.appLanguage = .korean
        #expect(vm.appLanguageNeedsRestart)

        vm.appLanguage = .english
        #expect(vm.appLanguageNeedsRestart == false)
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

    @Test func relaunchReopensTheOpenBookOrItsArchive() throws {
        let vm = makeTestViewModel()
        #expect(vm.relaunchBookURL == nil)

        let book = URL(fileURLWithPath: "/lib/Series/Vol02.cbz")
        vm.currentSourceURL = book
        vm.openedSourceURL = URL(fileURLWithPath: "/lib", isDirectory: true)
        #expect(vm.relaunchBookURL == book)

        // A volume extracted from an archive only exists in the temp dir;
        // the new instance has to reopen the archive itself.
        let archive = URL(fileURLWithPath: "/lib/Series.zip")
        let tempRoot = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        vm.tempDir.url = tempRoot
        vm.openedSourceURL = archive
        vm.currentSourceURL = tempRoot.appendingPathComponent("Vol02")
        #expect(vm.relaunchBookURL == archive)
    }
}
