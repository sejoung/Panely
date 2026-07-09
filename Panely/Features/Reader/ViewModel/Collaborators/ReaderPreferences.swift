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

    private let defaults: any KeyValueStoring

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

    init(defaults: any KeyValueStoring = LiveKeyValueStore()) {
        self.defaults = defaults

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
    }
}
