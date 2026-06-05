import Foundation

/// Per-series override of the presentation settings that characterize a body
/// of work rather than a personal app preference: reading direction, page
/// layout, and fit mode. Each field is optional — `nil` means "this series has
/// no opinion, fall back to the global default in `ReaderPreferences`".
///
/// `updatedAt` drives recency-based eviction (see the store's cap), mirroring
/// `ReadingProgress`.
struct SeriesReaderPreferences: Codable, Equatable {
    var direction: String? = nil
    var layout: String? = nil
    var fitMode: String? = nil
    var updatedAt: Date

    var isEmpty: Bool { direction == nil && layout == nil && fitMode == nil }
}

/// Remembers `direction` / `layout` / `fitMode` per series so opening a manga
/// series (RTL) vs. a western/webtoon series (LTR) restores the way you last
/// read *that* series, instead of one global setting for everything.
///
/// The effective value the reader uses is **series override ?? global
/// default** — resolution lives on `ReaderViewModel` (it applies the override
/// on load and writes through to both this store and the global preference on
/// change). Keyed by `ReaderSeriesIdentity`; capped by recency so a long
/// reading history can't grow `UserDefaults` without bound (mirrors
/// `ReadingProgressStore`).
@Observable
@MainActor
final class ReaderSeriesPreferencesStore {
    nonisolated static let storeKey = "panely.seriesPreferences"
    nonisolated static let maxEntries = 2000

    /// Keyed by series identifier. Internal (not private) so tests can assert
    /// persistence without reaching into `UserDefaults`.
    private(set) var entries: [String: SeriesReaderPreferences] = [:]

    private let defaults: any KeyValueStoring
    private let storeKey: String
    private let maxEntries: Int
    /// Injectable clock so recency eviction is deterministically testable.
    private let clock: @MainActor () -> Date

    init(
        defaults: any KeyValueStoring = LiveKeyValueStore(),
        storeKey: String = ReaderSeriesPreferencesStore.storeKey,
        maxEntries: Int = ReaderSeriesPreferencesStore.maxEntries,
        clock: @MainActor @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.storeKey = storeKey
        self.maxEntries = maxEntries
        self.clock = clock
        if let decoded = defaults.loadCodable([String: SeriesReaderPreferences].self, forKey: storeKey) {
            entries = decoded
        }
    }

    // MARK: - Lookup (typed)

    func direction(forSeries id: String) -> ReadingDirection? {
        prefs(forSeries: id)?.direction.flatMap(ReadingDirection.init(rawValue:))
    }

    func layout(forSeries id: String) -> PageLayout? {
        prefs(forSeries: id)?.layout.flatMap(PageLayout.init(rawValue:))
    }

    func fitMode(forSeries id: String) -> FitMode? {
        prefs(forSeries: id)?.fitMode.flatMap(FitMode.init(rawValue:))
    }

    func prefs(forSeries id: String) -> SeriesReaderPreferences? {
        guard !id.isEmpty else { return nil }
        return entries[id]
    }

    // MARK: - Recording (typed)

    func setDirection(_ value: ReadingDirection, forSeries id: String) {
        mutate(id) { $0.direction = value.rawValue }
    }

    func setLayout(_ value: PageLayout, forSeries id: String) {
        mutate(id) { $0.layout = value.rawValue }
    }

    func setFitMode(_ value: FitMode, forSeries id: String) {
        mutate(id) { $0.fitMode = value.rawValue }
    }

    // MARK: - Internals

    /// No-ops for an empty series id (no book open / standalone with no
    /// container) so callers can write through unconditionally.
    private func mutate(_ id: String, _ change: (inout SeriesReaderPreferences) -> Void) {
        guard !id.isEmpty else { return }
        var dict = entries
        var prefs = dict[id] ?? SeriesReaderPreferences(updatedAt: clock())
        change(&prefs)
        prefs.updatedAt = clock()
        dict[id] = prefs
        dict.capByRecency(to: maxEntries) { $0.updatedAt }
        entries = dict
        defaults.saveCodable(dict, forKey: storeKey)
    }
}
