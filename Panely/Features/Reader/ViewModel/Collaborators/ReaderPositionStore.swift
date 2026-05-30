import Foundation

/// Per-book reading position memory. In-memory mirror of the positions
/// dictionary backs the hot path (vertical scroll fires `setCurrentPageFromScroll`
/// at ~60Hz) — without it, every scroll tick walked a full UserDefaults
/// dictionary. Writes are debounced and coalesced; a sync flush is provided
/// for app termination so quit-during-scroll doesn't lose progress.
@MainActor
final class ReaderPositionStore {
    nonisolated static let positionsKey = "panely.positions"

    /// Cap on tracked position entries. Each is tiny (a key string plus an
    /// Int), but without a cap the dict grows by one or two entries for every
    /// unique book ever opened and is never trimmed — over a long reading
    /// history that bloats every `UserDefaults` round-trip. When exceeded,
    /// the least-recently-written keys are evicted using a persisted MRU
    /// order list so a book the user still reads keeps its position even
    /// across launches. ~4000 entries ≈ a couple hundred KB.
    nonisolated static let maxEntries = 4000

    /// In-memory mirror of the positions dict. Module-internal (not private)
    /// so tests can assert the lazy-hydration invariant — production code
    /// must go through `savePosition` / `restoredIndex` to keep the dict and
    /// the UserDefaults write paired.
    var cache: [String: Int]?
    /// MRU order mirror (most-recently-written key first). Persisted under
    /// `orderKey` so eviction survives relaunch.
    private var orderCache: [String]?
    private var pendingSaveTask: Task<Void, Never>?
    private let defaults: any KeyValueStoring
    private let positionsKey: String
    private let orderKey: String
    private let maxEntries: Int

    init(
        defaults: any KeyValueStoring = LiveKeyValueStore(),
        positionsKey: String = ReaderPositionStore.positionsKey,
        maxEntries: Int = ReaderPositionStore.maxEntries
    ) {
        self.defaults = defaults
        self.positionsKey = positionsKey
        self.orderKey = positionsKey + ".order"
        self.maxEntries = maxEntries
    }

    /// Schedule a debounced write. Rapid repeat calls coalesce into a single
    /// `UserDefaults` round-trip after ~300 ms of quiet. `fileIdentityKey`
    /// (when available) is mirrored alongside the primary key so external-
    /// drive mount-path drifts ("/Volumes/X" → "/Volumes/X 1") still recover.
    func savePosition(forKey key: String, fileIdentityKey: String?, pageIndex: Int) {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.writeNow(key: key, fileIdentityKey: fileIdentityKey, pageIndex: pageIndex)
        }
    }

    /// Synchronous flush. Used by the app-terminate observer and by the
    /// debounced path after its sleep expires.
    func flushImmediately(forKey key: String, fileIdentityKey: String?, pageIndex: Int) {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        writeNow(key: key, fileIdentityKey: fileIdentityKey, pageIndex: pageIndex)
    }

    /// Restored page index for `key`, falling back to `fileIdentityKey` so a
    /// renamed/remounted file recovers its position. Returns 0 when nothing
    /// matches.
    func restoredIndex(forKey key: String, fileIdentityKey: String?) -> Int {
        let dict = loaded()
        if let primary = dict[key] { return primary }
        if let fid = fileIdentityKey, let secondary = dict[fid] { return secondary }
        return 0
    }

    // MARK: - URL-based addressing

    /// Stable primary key for `sourceURL`. Centralises `PositionKey` derivation
    /// here so callers (viewmodel, bookmark facade) don't each build their own.
    func primaryKey(for sourceURL: URL, opened openedURL: URL?, tempRoot: URL?) -> String {
        PositionKey.keys(for: sourceURL, opened: openedURL, tempRoot: tempRoot).primary
    }

    func savePosition(
        for sourceURL: URL,
        opened openedURL: URL?,
        tempRoot: URL?,
        pageIndex: Int
    ) {
        let keys = PositionKey.keys(for: sourceURL, opened: openedURL, tempRoot: tempRoot)
        savePosition(forKey: keys.primary, fileIdentityKey: keys.fileIdentity, pageIndex: pageIndex)
    }

    func flushImmediately(
        for sourceURL: URL,
        opened openedURL: URL?,
        tempRoot: URL?,
        pageIndex: Int
    ) {
        let keys = PositionKey.keys(for: sourceURL, opened: openedURL, tempRoot: tempRoot)
        flushImmediately(forKey: keys.primary, fileIdentityKey: keys.fileIdentity, pageIndex: pageIndex)
    }

    func restoredIndex(
        for sourceURL: URL,
        opened openedURL: URL?,
        tempRoot: URL?
    ) -> Int {
        let keys = PositionKey.keys(for: sourceURL, opened: openedURL, tempRoot: tempRoot)
        return restoredIndex(forKey: keys.primary, fileIdentityKey: keys.fileIdentity)
    }

    private func writeNow(key: String, fileIdentityKey: String?, pageIndex: Int) {
        var dict = loaded()
        var order = loadedOrder(dict: dict)

        dict[key] = pageIndex
        if let fid = fileIdentityKey {
            dict[fid] = pageIndex
        }

        // Promote the touched keys to the front (most-recently-used).
        let touched = [key, fileIdentityKey].compactMap { $0 }
        order.removeAll { touched.contains($0) }
        order.insert(contentsOf: touched, at: 0)

        evictIfNeeded(dict: &dict, order: &order)

        cache = dict
        orderCache = order
        defaults.set(dict, forKey: positionsKey)
        defaults.set(order, forKey: orderKey)
    }

    /// Drop least-recently-written entries until the dict is back under the
    /// cap. `order` is MRU-first, so the eviction candidates are at its tail.
    private func evictIfNeeded(dict: inout [String: Int], order: inout [String]) {
        guard dict.count > maxEntries else { return }
        while dict.count > maxEntries, let stale = order.popLast() {
            dict.removeValue(forKey: stale)
        }
        // Defensive: if the order list somehow under-counts the dict (it
        // shouldn't — `loadedOrder` seeds every dict key), drop arbitrary
        // extras so the cap is always honored.
        if dict.count > maxEntries {
            for extra in dict.keys.shuffled().prefix(dict.count - maxEntries) {
                dict.removeValue(forKey: extra)
            }
        }
    }

    /// Lazy hydration. First call pays one UserDefaults syscall; subsequent
    /// calls hit the in-memory mirror until something invalidates it (we
    /// never do — the dict is mutated in place on every write).
    private func loaded() -> [String: Int] {
        if let cached = cache { return cached }
        let loaded = defaults.dictionary(forKey: positionsKey) as? [String: Int] ?? [:]
        cache = loaded
        return loaded
    }

    /// MRU order, reconciled against `dict`: any dict key without a recorded
    /// position in the order list (entries that predate order tracking, or a
    /// direct defaults write) is appended so it's still an eviction candidate
    /// but ranks below anything explicitly touched; stale order entries no
    /// longer in the dict are dropped.
    private func loadedOrder(dict: [String: Int]) -> [String] {
        var order = orderCache ?? (defaults.array(forKey: orderKey) as? [String] ?? [])
        let known = Set(order)
        let missing = dict.keys.filter { !known.contains($0) }
        if !missing.isEmpty {
            order.append(contentsOf: missing)
        }
        order.removeAll { dict[$0] == nil }
        orderCache = order
        return order
    }
}
