import Foundation

/// User-facing reader preferences persisted via `UserDefaults`. Each property
/// writes itself through on assignment, so callers can mutate freely and the
/// next launch reads the current state back from disk. `ReaderViewModel`
/// composes one of these and forwards its own `layout` / `fitMode` / …
/// properties through, keeping the public viewmodel API stable.
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
    }
}
