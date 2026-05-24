import Testing
import Foundation
@testable import Panely

/// Round-trip tests for `ReaderPreferences`. UserDefaults is process-global,
/// so each test scrubs every key it touches both before (in case a prior
/// run aborted mid-test) and after via defer.
@MainActor
struct ReaderPreferencesTests {

    // MARK: - Init reads existing values

    @Test func initLeavesDefaultsWhenUserDefaultsIsEmpty() {
        clearAllPrefKeys()
        defer { clearAllPrefKeys() }

        let prefs = ReaderPreferences()

        #expect(prefs.layout == .single)
        #expect(prefs.direction == .leftToRight)
        #expect(prefs.fitMode == .fitScreen)
        #expect(prefs.autoFitOnResize == true)
        #expect(prefs.toolbarPinned == false)
        #expect(prefs.thumbnailSidebarVisible == false)
        #expect(prefs.sidebarMode.pinned == true)
    }

    @Test func initHydratesEachPropertyFromUserDefaults() {
        clearAllPrefKeys()
        defer { clearAllPrefKeys() }

        UserDefaults.standard.set(PageLayout.vertical.rawValue, forKey: ReaderPreferences.layoutKey)
        UserDefaults.standard.set(ReadingDirection.rightToLeft.rawValue, forKey: ReaderPreferences.directionKey)
        UserDefaults.standard.set(FitMode.fitWidth.rawValue, forKey: ReaderPreferences.fitModeKey)
        UserDefaults.standard.set(false, forKey: ReaderPreferences.autoFitOnResizeKey)
        UserDefaults.standard.set(true, forKey: ReaderPreferences.toolbarPinnedKey)
        UserDefaults.standard.set(true, forKey: ReaderPreferences.thumbnailSidebarVisibleKey)
        UserDefaults.standard.set(true, forKey: ReaderPreferences.sidebarPinnedKey)

        let prefs = ReaderPreferences()

        #expect(prefs.layout == .vertical)
        #expect(prefs.direction == .rightToLeft)
        #expect(prefs.fitMode == .fitWidth)
        #expect(prefs.autoFitOnResize == false)
        #expect(prefs.toolbarPinned == true)
        #expect(prefs.thumbnailSidebarVisible == true)
        #expect(prefs.sidebarMode.pinned == true)
    }

    @Test func initIgnoresInvalidRawValuesAndKeepsDefaults() {
        clearAllPrefKeys()
        defer { clearAllPrefKeys() }

        // Garbage left by a hand-edited plist or a future-version downgrade.
        // The init guards `PageLayout(rawValue:)` etc. — invalid input must
        // fall back to the type's hardcoded default, not crash.
        UserDefaults.standard.set("notARealLayout", forKey: ReaderPreferences.layoutKey)
        UserDefaults.standard.set("notARealDirection", forKey: ReaderPreferences.directionKey)
        UserDefaults.standard.set("notARealFitMode", forKey: ReaderPreferences.fitModeKey)

        let prefs = ReaderPreferences()

        #expect(prefs.layout == .single)
        #expect(prefs.direction == .leftToRight)
        #expect(prefs.fitMode == .fitScreen)
    }

    // MARK: - Legacy sidebar migration

    @Test func legacySidebarVisibleMigratesToPinnedWhenModernKeyAbsent() {
        clearAllPrefKeys()
        defer { clearAllPrefKeys() }

        // Pre-1.x build: there was only `sidebarVisible: Bool` meaning
        // "always visible". The new `sidebarPinned: Bool` is the same
        // concept under a new name. First launch after upgrade must carry
        // the user's "always visible" preference over.
        UserDefaults.standard.set(true, forKey: ReaderPreferences.legacySidebarVisibleKey)

        let prefs = ReaderPreferences()

        #expect(prefs.sidebarMode.pinned == true)
    }

    @Test func modernSidebarPinnedKeyOverridesLegacyValue() {
        clearAllPrefKeys()
        defer { clearAllPrefKeys() }

        // If both keys are present, the user has already set the new
        // pinned key — that's the source of truth. The legacy value is
        // only consulted when the modern key is absent.
        UserDefaults.standard.set(true, forKey: ReaderPreferences.legacySidebarVisibleKey)
        UserDefaults.standard.set(false, forKey: ReaderPreferences.sidebarPinnedKey)

        let prefs = ReaderPreferences()

        #expect(prefs.sidebarMode.pinned == false)
    }

    // MARK: - didSet persistence

    @Test func mutatingEachPropertyPersistsThroughUserDefaults() {
        clearAllPrefKeys()
        defer { clearAllPrefKeys() }

        let prefs = ReaderPreferences()
        prefs.layout = .double
        prefs.direction = .rightToLeft
        prefs.fitMode = .fitHeight
        prefs.autoFitOnResize = false
        prefs.toolbarPinned = true
        prefs.thumbnailSidebarVisible = true
        prefs.sidebarMode.pinned = true

        // A second instance reads back everything from disk — proves the
        // didSet actually rounded-tripped, not just landed in the live
        // observable instance.
        let reloaded = ReaderPreferences()
        #expect(reloaded.layout == .double)
        #expect(reloaded.direction == .rightToLeft)
        #expect(reloaded.fitMode == .fitHeight)
        #expect(reloaded.autoFitOnResize == false)
        #expect(reloaded.toolbarPinned == true)
        #expect(reloaded.thumbnailSidebarVisible == true)
        #expect(reloaded.sidebarMode.pinned == true)
    }

    @Test func sidebarTogglePinPersistsBothDirections() {
        clearAllPrefKeys()
        defer { clearAllPrefKeys() }

        let prefs = ReaderPreferences()
        prefs.sidebarMode.togglePin() // true → false
        #expect(ReaderPreferences().sidebarMode.pinned == false)

        prefs.sidebarMode.togglePin() // false → true
        #expect(ReaderPreferences().sidebarMode.pinned == true)
    }

    // MARK: - Helpers

    private func clearAllPrefKeys() {
        for key in [
            ReaderPreferences.layoutKey,
            ReaderPreferences.directionKey,
            ReaderPreferences.fitModeKey,
            ReaderPreferences.autoFitOnResizeKey,
            ReaderPreferences.toolbarPinnedKey,
            ReaderPreferences.thumbnailSidebarVisibleKey,
            ReaderPreferences.sidebarPinnedKey,
            ReaderPreferences.legacySidebarVisibleKey,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
