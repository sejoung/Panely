import Testing
import Foundation
@testable import Panely

@MainActor
struct ReaderPreferencesTests {

    // MARK: - Init reads existing values

    @Test func initLeavesDefaultsWhenStoreIsEmpty() {
        let defaults = InMemoryKeyValueStore()

        let prefs = ReaderPreferences(defaults: defaults)

        #expect(prefs.layout == .single)
        #expect(prefs.direction == .leftToRight)
        #expect(prefs.fitMode == .fitScreen)
        #expect(prefs.autoFitOnResize == true)
        #expect(prefs.toolbarPinned == false)
        #expect(prefs.thumbnailSidebarVisible == false)
        #expect(prefs.sidebarMode.pinned == true)
        #expect(prefs.wheelPageTurn == true)
    }

    @Test func initHydratesEachPropertyFromStore() {
        let defaults = InMemoryKeyValueStore([
            ReaderPreferences.layoutKey: PageLayout.vertical.rawValue,
            ReaderPreferences.directionKey: ReadingDirection.rightToLeft.rawValue,
            ReaderPreferences.fitModeKey: FitMode.fitWidth.rawValue,
            ReaderPreferences.autoFitOnResizeKey: false,
            ReaderPreferences.toolbarPinnedKey: true,
            ReaderPreferences.thumbnailSidebarVisibleKey: true,
            ReaderPreferences.sidebarPinnedKey: true,
            ReaderPreferences.wheelPageTurnKey: false,
        ])

        let prefs = ReaderPreferences(defaults: defaults)

        #expect(prefs.layout == .vertical)
        #expect(prefs.direction == .rightToLeft)
        #expect(prefs.fitMode == .fitWidth)
        #expect(prefs.autoFitOnResize == false)
        #expect(prefs.toolbarPinned == true)
        #expect(prefs.thumbnailSidebarVisible == true)
        #expect(prefs.sidebarMode.pinned == true)
        #expect(prefs.wheelPageTurn == false)
    }

    @Test func initIgnoresInvalidRawValuesAndKeepsDefaults() {
        let defaults = InMemoryKeyValueStore([
            ReaderPreferences.layoutKey: "notARealLayout",
            ReaderPreferences.directionKey: "notARealDirection",
            ReaderPreferences.fitModeKey: "notARealFitMode",
        ])

        let prefs = ReaderPreferences(defaults: defaults)

        #expect(prefs.layout == .single)
        #expect(prefs.direction == .leftToRight)
        #expect(prefs.fitMode == .fitScreen)
    }

    // MARK: - Legacy sidebar migration

    @Test func legacySidebarVisibleMigratesToPinnedWhenModernKeyAbsent() {
        let defaults = InMemoryKeyValueStore([
            ReaderPreferences.legacySidebarVisibleKey: true,
        ])

        let prefs = ReaderPreferences(defaults: defaults)

        #expect(prefs.sidebarMode.pinned == true)
    }

    @Test func modernSidebarPinnedKeyOverridesLegacyValue() {
        let defaults = InMemoryKeyValueStore([
            ReaderPreferences.legacySidebarVisibleKey: true,
            ReaderPreferences.sidebarPinnedKey: false,
        ])

        let prefs = ReaderPreferences(defaults: defaults)

        #expect(prefs.sidebarMode.pinned == false)
    }

    // MARK: - didSet persistence

    @Test func mutatingEachPropertyPersistsThroughStore() {
        let defaults = InMemoryKeyValueStore()

        let prefs = ReaderPreferences(defaults: defaults)
        prefs.layout = .double
        prefs.direction = .rightToLeft
        prefs.fitMode = .fitHeight
        prefs.autoFitOnResize = false
        prefs.toolbarPinned = true
        prefs.thumbnailSidebarVisible = true
        prefs.sidebarMode.pinned = true
        prefs.wheelPageTurn = false

        // A second instance reads back everything from persistence — proves the
        // didSet actually rounded-tripped, not just landed in the live
        // observable instance.
        let reloaded = ReaderPreferences(defaults: defaults)
        #expect(reloaded.layout == .double)
        #expect(reloaded.direction == .rightToLeft)
        #expect(reloaded.fitMode == .fitHeight)
        #expect(reloaded.autoFitOnResize == false)
        #expect(reloaded.toolbarPinned == true)
        #expect(reloaded.thumbnailSidebarVisible == true)
        #expect(reloaded.sidebarMode.pinned == true)
        #expect(reloaded.wheelPageTurn == false)
    }

    @Test func sidebarTogglePinPersistsBothDirections() {
        let defaults = InMemoryKeyValueStore()

        let prefs = ReaderPreferences(defaults: defaults)
        prefs.sidebarMode.togglePin() // true → false
        #expect(ReaderPreferences(defaults: defaults).sidebarMode.pinned == false)

        prefs.sidebarMode.togglePin() // false → true
        #expect(ReaderPreferences(defaults: defaults).sidebarMode.pinned == true)
    }

    // MARK: - Interface language

    @Test func appLanguageDefaultsToSystemWithoutOverride() {
        let defaults = InMemoryKeyValueStore()

        let prefs = ReaderPreferences(defaults: defaults, systemLanguages: { ["ko-KR", "en"] })

        #expect(prefs.appLanguage == .system)
        #expect(defaults.array(forKey: ReaderPreferences.appleLanguagesKey) == nil)
    }

    @Test func choosingALanguageOverridesAppleLanguages() {
        let defaults = InMemoryKeyValueStore()
        let prefs = ReaderPreferences(defaults: defaults, systemLanguages: { ["ko-KR"] })

        prefs.appLanguage = .english
        #expect(defaults.array(forKey: ReaderPreferences.appleLanguagesKey) as? [String] == ["en"])

        prefs.appLanguage = .korean
        #expect(defaults.array(forKey: ReaderPreferences.appleLanguagesKey) as? [String] == ["ko"])
        #expect(ReaderPreferences(defaults: defaults).appLanguage == .korean)
    }

    @Test func systemDefaultOnASupportedLanguageLeavesItToMacOS() {
        let defaults = InMemoryKeyValueStore()
        let prefs = ReaderPreferences(defaults: defaults, systemLanguages: { ["ko-KR", "en"] })
        prefs.appLanguage = .english

        prefs.appLanguage = .system

        #expect(defaults.array(forKey: ReaderPreferences.appleLanguagesKey) == nil)
        #expect(ReaderPreferences(defaults: defaults).appLanguage == .system)
    }

    @Test func systemDefaultOnAnUnsupportedLanguageFallsBackToEnglish() {
        // Without the override macOS would pick Korean — the next supported
        // language in the list — for its own menus while Panely shows English.
        let defaults = InMemoryKeyValueStore()
        let prefs = ReaderPreferences(defaults: defaults, systemLanguages: { ["ja-JP", "ko-KR"] })

        prefs.appLanguage = .system

        #expect(defaults.array(forKey: ReaderPreferences.appleLanguagesKey) as? [String] == ["en"])
    }

    @Test func refreshingTheOverrideTracksAChangedSystemLanguage() {
        var system = ["ja-JP"]
        let defaults = InMemoryKeyValueStore()
        let prefs = ReaderPreferences(defaults: defaults, systemLanguages: { system })
        prefs.refreshAppleLanguagesOverride()
        #expect(defaults.array(forKey: ReaderPreferences.appleLanguagesKey) as? [String] == ["en"])

        system = ["ko-KR"]
        prefs.refreshAppleLanguagesOverride()

        #expect(defaults.array(forKey: ReaderPreferences.appleLanguagesKey) == nil)
    }

    @Test func unknownStoredLanguageFallsBackToSystem() {
        let defaults = InMemoryKeyValueStore([ReaderPreferences.appLanguageKey: "klingon"])
        #expect(ReaderPreferences(defaults: defaults).appLanguage == .system)
    }
}
