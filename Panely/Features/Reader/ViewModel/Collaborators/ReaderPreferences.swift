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

    var layout: PageLayout = .single {
        didSet {
            UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey)
        }
    }

    var direction: ReadingDirection = .leftToRight {
        didSet {
            UserDefaults.standard.set(direction.rawValue, forKey: Self.directionKey)
        }
    }

    var sidebarMode = SidebarMode() {
        didSet {
            UserDefaults.standard.set(sidebarMode.pinned, forKey: Self.sidebarPinnedKey)
        }
    }

    var fitMode: FitMode = .fitScreen {
        didSet {
            UserDefaults.standard.set(fitMode.rawValue, forKey: Self.fitModeKey)
        }
    }

    var autoFitOnResize: Bool = true {
        didSet {
            UserDefaults.standard.set(autoFitOnResize, forKey: Self.autoFitOnResizeKey)
        }
    }

    var toolbarPinned: Bool = false {
        didSet {
            UserDefaults.standard.set(toolbarPinned, forKey: Self.toolbarPinnedKey)
        }
    }

    var thumbnailSidebarVisible: Bool = false {
        didSet {
            UserDefaults.standard.set(thumbnailSidebarVisible, forKey: Self.thumbnailSidebarVisibleKey)
        }
    }

    init() {
        // Snapshot once. Each individual `UserDefaults.standard.string(...)`
        // / `.bool(...)` / `.object(...)` call is a syscall + KVO check; on
        // cold start the dozen lookups added up to ~10–50 ms. A single
        // `dictionaryRepresentation()` is one cross-process trip and we
        // type-cast from in-memory dict locally.
        let defaults = UserDefaults.standard.dictionaryRepresentation()

        if let raw = defaults[Self.layoutKey] as? String,
           let stored = PageLayout(rawValue: raw) {
            layout = stored
        }
        if let raw = defaults[Self.directionKey] as? String,
           let stored = ReadingDirection(rawValue: raw) {
            direction = stored
        }
        if let pinned = defaults[Self.sidebarPinnedKey] as? Bool {
            sidebarMode.pinned = pinned
        } else if let legacy = defaults[Self.legacySidebarVisibleKey] as? Bool {
            // Migrate prior "always visible" preference to the new pinned mode.
            sidebarMode.pinned = legacy
        }
        if let raw = defaults[Self.fitModeKey] as? String,
           let stored = FitMode(rawValue: raw) {
            fitMode = stored
        }
        if let value = defaults[Self.autoFitOnResizeKey] as? Bool {
            autoFitOnResize = value
        }
        if let value = defaults[Self.toolbarPinnedKey] as? Bool {
            toolbarPinned = value
        }
        if let value = defaults[Self.thumbnailSidebarVisibleKey] as? Bool {
            thumbnailSidebarVisible = value
        }
    }
}
