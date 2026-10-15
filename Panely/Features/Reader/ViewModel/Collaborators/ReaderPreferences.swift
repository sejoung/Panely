import Foundation

/// Canonical owner of all reader **UI/chrome state**: page layout, reading
/// direction, sidebar/toolbar pin state, thumbnail sidebar visibility, fit
/// mode, auto-fit-on-resize. Each property writes itself through to
/// `UserDefaults` on assignment, so callers can mutate freely and the next
/// launch reads the current state back from disk.
///
/// `ReaderViewModel` holds one of these and exposes forwarding computed
/// properties (`viewModel.layout`, `.direction`, …) for view callsites — the
/// VM keeps domain state (open book, current page, siblings), this object
/// keeps presentation state. The split is intentional: clearing a book never
/// resets the user's layout preference.
@Observable
@MainActor
final class ReaderPreferences {
    static let layoutKey = "panely.layout"
    static let directionKey = "panely.direction"
    static let sidebarPinnedKey = "panely.sidebarPinned"
    static let legacySidebarVisibleKey = "panely.sidebarVisible"
    static let fitModeKey = "panely.fitMode"
    static let autoFitOnResizeKey = "panely.autoFitOnResize"
    static let toolbarPinnedKey = "panely.toolbarPinned"
    static let thumbnailSidebarVisibleKey = "panely.thumbnailSidebarVisible"
    static let doublePageCoverAloneKey = "panely.doublePageCoverAlone"
    static let reopenLastFolderOnLaunchKey = "panely.reopenLastFolderOnLaunch"
    static let wheelPageTurnKey = "panely.wheelPageTurn"
    static let appLanguageKey = "panely.appLanguage"
    static let translationEnabledKey = "panely.translation.enabled"
    static let translationIncludeSoundEffectsKey = "panely.translation.includeSoundEffects"
    static let translationModeKey = "panely.translation.mode"
    static let translationTargetLanguageKey = "panely.translation.targetLanguage"
    static let translationOverlayVisibleKey = "panely.translation.overlayVisible"
    static let translationBalloonTipDismissedKey = "panely.translation.balloonTipDismissed"
    /// Read by AppKit at launch to pick the app's localization. Written into
    /// Panely's own defaults only — the system-wide list is never touched.
    static let appleLanguagesKey = "AppleLanguages"

    private let defaults: any KeyValueStoring
    /// The Mac's language list — injectable so tests don't depend on the
    /// machine they run on.
    private let systemLanguages: () -> [String]

    var layout: PageLayout = .single {
        didSet {
            defaults.set(layout.rawValue, forKey: Self.layoutKey)
        }
    }

    var direction: ReadingDirection = .leftToRight {
        didSet {
            defaults.set(direction.rawValue, forKey: Self.directionKey)
        }
    }

    var sidebarMode = SidebarMode(pinned: true) {
        didSet {
            defaults.set(sidebarMode.pinned, forKey: Self.sidebarPinnedKey)
        }
    }

    var fitMode: FitMode = .fitScreen {
        didSet {
            defaults.set(fitMode.rawValue, forKey: Self.fitModeKey)
        }
    }

    var autoFitOnResize: Bool = true {
        didSet {
            defaults.set(autoFitOnResize, forKey: Self.autoFitOnResizeKey)
        }
    }

    var toolbarPinned: Bool = false {
        didSet {
            defaults.set(toolbarPinned, forKey: Self.toolbarPinnedKey)
        }
    }

    var thumbnailSidebarVisible: Bool = false {
        didSet {
            defaults.set(thumbnailSidebarVisible, forKey: Self.thumbnailSidebarVisibleKey)
        }
    }

    /// Double-page only: when true, page 0 is shown alone so facing spreads
    /// pair as 0 | (1,2) (3,4)… instead of (0,1) (2,3)…. Off by default to
    /// preserve the historical pairing; users flip it when a book's standalone
    /// cover makes every spread look shifted by one. See `SpreadCalculator`.
    var doublePageCoverAlone: Bool = false {
        didSet {
            defaults.set(doublePageCoverAlone, forKey: Self.doublePageCoverAloneKey)
        }
    }

    /// Whether a cold launch reopens the last browsed library folder. On by
    /// default (the convenience the folder bookmark exists for); users turn it
    /// off to always start empty. See `ReaderViewModel.restoreLastLibraryRootIfNeeded`.
    var reopenLastFolderOnLaunch: Bool = true {
        didSet {
            defaults.set(reopenLastFolderOnLaunch, forKey: Self.reopenLastFolderOnLaunchKey)
        }
    }

    /// Paged layouts only: when true, a plain scroll (wheel or trackpad)
    /// turns the page once the current page has no more room to pan — scroll
    /// down = next, up = previous (see `WheelPageTurnEngine`). Never applies
    /// to the continuous/vertical layout, where scrolling is reading. On by
    /// default (the comic-reader convention); toggled from the View menu by
    /// users who want scrolling to only ever pan.
    var wheelPageTurn: Bool = true {
        didSet {
            defaults.set(wheelPageTurn, forKey: Self.wheelPageTurnKey)
        }
    }

    /// Interface language choice (see `AppLanguage`). Panely's own UI
    /// follows it immediately through `AppLocalization`; the mirrored
    /// `AppMenuLocalizer` updates native menus live. The mirrored
    /// `AppleLanguages` also sets the language for future launches.
    var appLanguage: AppLanguage = .system {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Self.appLanguageKey)
            refreshAppleLanguagesOverride()
        }
    }

    /// Experimental translation assist (macOS 26+). Off by default: it runs
    /// OCR and on-device translation over the user's pages, which is heavy and
    /// only useful to people reading comics in a language they don't read.
    var translationEnabled: Bool = false {
        didSet {
            defaults.set(translationEnabled, forKey: Self.translationEnabledKey)
        }
    }

    /// Translate onomatopoeia too. Off by default: sound effects are drawn
    /// art more than dialogue, and each costs a second of translation time.
    /// (The book's own language is per series — see `ReaderSeriesPreferencesStore`.)
    var translationIncludeSoundEffects: Bool = false {
        didSet {
            defaults.set(translationIncludeSoundEffects, forKey: Self.translationIncludeSoundEffectsKey)
        }
    }

    /// Which translation model runs. Fast by default: the assist is for
    /// following the story, and the accurate model takes ~20× as long (see
    /// `TranslationMode`).
    var translationMode: TranslationMode = .fast {
        didSet {
            defaults.set(translationMode.rawValue, forKey: Self.translationModeKey)
        }
    }

    /// Language to translate into; `nil` follows the interface language
    /// (see `ReaderViewModel.translationTargetLanguage`).
    var translationTargetLanguage: TranslationLanguage? {
        didSet {
            defaults.set(translationTargetLanguage?.rawValue, forKey: Self.translationTargetLanguageKey)
        }
    }

    /// Whether translated text is painted over the page. When off, balloons
    /// still open their original + translation popover on click.
    var translationOverlayVisible: Bool = true {
        didSet {
            defaults.set(translationOverlayVisible, forKey: Self.translationOverlayVisibleKey)
        }
    }

    /// The translation panel's "click a balloon" tip was dismissed.
    var translationBalloonTipDismissed: Bool = false {
        didSet {
            defaults.set(translationBalloonTipDismissed, forKey: Self.translationBalloonTipDismissedKey)
        }
    }

    /// Re-derive the `AppleLanguages` override. Also run at launch: under
    /// "System Default" the right value depends on the Mac's language, which
    /// may have changed since it was last written.
    func refreshAppleLanguagesOverride() {
        defaults.set(
            AppLocalization.appleLanguagesOverride(for: appLanguage, systemLanguages: systemLanguages()),
            forKey: Self.appleLanguagesKey
        )
    }

    init(
        defaults: any KeyValueStoring = LiveKeyValueStore(),
        systemLanguages: @escaping () -> [String] = { AppLocalization.systemPreferredLanguages() }
    ) {
        self.defaults = defaults
        self.systemLanguages = systemLanguages

        // Snapshot once. Each individual defaults lookup
        // / `.bool(...)` / `.object(...)` call is a syscall + KVO check; on
        // cold start the dozen lookups added up to ~10–50 ms. A single
        // `dictionaryRepresentation()` is one cross-process trip and we
        // type-cast from in-memory dict locally.
        let storedDefaults = defaults.dictionaryRepresentation()

        if let raw = storedDefaults[Self.layoutKey] as? String,
           let stored = PageLayout(rawValue: raw) {
            layout = stored
        }
        if let raw = storedDefaults[Self.directionKey] as? String,
           let stored = ReadingDirection(rawValue: raw) {
            direction = stored
        }
        if let pinned = storedDefaults[Self.sidebarPinnedKey] as? Bool {
            sidebarMode.pinned = pinned
        } else if let legacy = storedDefaults[Self.legacySidebarVisibleKey] as? Bool {
            // Migrate prior "always visible" preference to the new pinned mode.
            sidebarMode.pinned = legacy
        }
        if let raw = storedDefaults[Self.fitModeKey] as? String,
           let stored = FitMode(rawValue: raw) {
            fitMode = stored
        }
        if let value = storedDefaults[Self.autoFitOnResizeKey] as? Bool {
            autoFitOnResize = value
        }
        if let value = storedDefaults[Self.toolbarPinnedKey] as? Bool {
            toolbarPinned = value
        }
        if let value = storedDefaults[Self.thumbnailSidebarVisibleKey] as? Bool {
            thumbnailSidebarVisible = value
        }
        if let value = storedDefaults[Self.doublePageCoverAloneKey] as? Bool {
            doublePageCoverAlone = value
        }
        if let value = storedDefaults[Self.reopenLastFolderOnLaunchKey] as? Bool {
            reopenLastFolderOnLaunch = value
        }
        if let value = storedDefaults[Self.wheelPageTurnKey] as? Bool {
            wheelPageTurn = value
        }
        if let raw = storedDefaults[Self.appLanguageKey] as? String,
           let stored = AppLanguage(rawValue: raw) {
            appLanguage = stored
        }
        if let value = storedDefaults[Self.translationEnabledKey] as? Bool {
            translationEnabled = value
        }
        if let value = storedDefaults[Self.translationIncludeSoundEffectsKey] as? Bool {
            translationIncludeSoundEffects = value
        }
        if let raw = storedDefaults[Self.translationModeKey] as? String,
           let stored = TranslationMode(rawValue: raw) {
            translationMode = stored
        }
        if let raw = storedDefaults[Self.translationTargetLanguageKey] as? String,
           let stored = TranslationLanguage(rawValue: raw) {
            translationTargetLanguage = stored
        }
        if let value = storedDefaults[Self.translationOverlayVisibleKey] as? Bool {
            translationOverlayVisible = value
        }
        if let value = storedDefaults[Self.translationBalloonTipDismissedKey] as? Bool {
            translationBalloonTipDismissed = value
        }
    }
}
