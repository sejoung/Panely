import Testing
import Foundation
@testable import Panely

/// "System Default" follows the Mac's *primary* language when Panely ships
/// it, and falls back to English otherwise.
struct AppLocalizationTests {

    @Test(arguments: [
        (["ko-KR", "en"], "ko"),
        (["ko"], "ko"),
        (["en-GB"], "en"),
        (["en-US", "ko-KR"], "en"),
        (["ja-JP", "ko-KR"], "en"),
        (["zh-Hans-CN"], "en"),
        ([], "en"),
    ])
    func systemDefaultResolution(systemLanguages: [String], expected: String) {
        #expect(AppLocalization.resolve(.system, systemLanguages: systemLanguages) == expected)
    }

    @Test func explicitChoiceIgnoresTheSystemLanguage() {
        #expect(AppLocalization.resolve(.english, systemLanguages: ["ko-KR"]) == "en")
        #expect(AppLocalization.resolve(.korean, systemLanguages: ["ja-JP"]) == "ko")
    }

    @Test func applySwitchesTheLookupBundle() {
        let localization = AppLocalization(language: "en")
        #expect(String(localized: "Language", bundle: localization.bundle) == "Language")

        localization.apply(.korean)
        #expect(String(localized: "Language", bundle: localization.bundle) == "언어")

        localization.apply(.system, systemLanguages: ["ja-JP"])
        #expect(localization.language == "en")
        #expect(String(localized: "Language", bundle: localization.bundle) == "Language")
    }

    @Test func englishLookupWorksEvenWhenTheProcessIsKorean() {
        // The English table must exist on its own (en.lproj); otherwise a
        // Korean launch switched to English would keep Korean text.
        #expect(Bundle.main.path(forResource: "en", ofType: "lproj") != nil)
    }

    @Test func languageChangesAreObservable() {
        let localization = AppLocalization(language: "en")
        var changed = false
        withObservationTracking {
            _ = localization.bundle
        } onChange: {
            changed = true
        }

        localization.apply(.korean)

        #expect(changed)
    }
}
