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
    /// Quiet period before a debounced write lands (see
    /// `ReadingProgressStore.saveDelay`). Every write bridges the whole
    /// dictionary and order list into `UserDefaults` on the main thread.
    nonisolated static let saveDelay: Duration = .seconds(2)

    /// In-memory mirror of the positions dict. Module-internal (not private)
    /// so tests can assert the lazy-hydration invariant — production code
    /// must go through `savePosition` / `restoredIndex` to keep the dict and
    /// the UserDefaults write paired.
    var cache: [String: Int]?
    /// MRU order mirror (most-recently-written key first). Persisted under
    /// `orderKey` so eviction survives relaunch. Reconciled against `cache`
    /// once on hydration, then kept in step by every write.
    private var orderCache: [String]?
    /// Module-internal so tests can flush the pending write instead of
    /// waiting out the delay.
    let saveDebouncer = Debouncer(delay: ReaderPositionStore.saveDelay)
    /// The write waiting in `saveDebouncer`. The debouncer is shared by every
    /// book, so a write for a different key flushes this one first rather
    /// than replacing it (see `ReadingProgressStore.pendingKey`). Also
    /// consulted by `restoredIndex`, so reopening the same book inside the
    /// debounce window restores the page just left, not the one before it.
    private var pending: (key: String, fileIdentityKey: String?, pageIndex: Int)?
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
    /// `UserDefaults` round-trip after `saveDelay` of quiet. `fileIdentityKey`
    /// (when available) is mirrored alongside the primary key so external-
    /// drive mount-path drifts ("/Volumes/X" → "/Volumes/X 1") still recover.
    func savePosition(forKey key: String, fileIdentityKey: String?, pageIndex: Int) {
        if pending?.key != key { saveDebouncer.flush() }
        pending = (key, fileIdentityKey, pageIndex)
        saveDebouncer.schedule { [weak self] in
            self?.writeNow(key: key, fileIdentityKey: fileIdentityKey, pageIndex: pageIndex)
        }
    }

    /// Synchronous flush. Used by the app-terminate observer and by the
    /// debounced path after its sleep expires.
    func flushImmediately(forKey key: String, fileIdentityKey: String?, pageIndex: Int) {
        if pending?.key != key { saveDebouncer.flush() }
        saveDebouncer.cancel()
        writeNow(key: key, fileIdentityKey: fileIdentityKey, pageIndex: pageIndex)
    }

    /// Restored page index for `key`, falling back to `fileIdentityKey` so a
    /// renamed/remounted file recovers its position. Returns 0 when nothing
    /// matches. A still-debounced write reads as if it had already landed.
    func restoredIndex(forKey key: String, fileIdentityKey: String?) -> Int {
        if let primary = storedIndex(forKey: key) { return primary }
        if let fid = fileIdentityKey, let secondary = storedIndex(forKey: fid) { return secondary }
        return 0
    }

    // MARK: - URL-based addressing

    /// Stable primary key for `sourceURL`. Centralises `PositionKey` derivation
    /// here so callers (viewmodel, bookmark facade) don't each build their own.
    /// Path-only (`PositionKey.make`): unlike `PositionKey.keys` it never stats
    /// the file for its identity, so it's cheap enough for render paths.
    func primaryKey(for sourceURL: URL, opened openedURL: URL?, tempRoot: URL?) -> String {
        PositionKey.make(for: sourceURL, opened: openedURL, tempRoot: tempRoot)
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

    func migrateSourcePath(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        // Land the pending write under its old key so the migration carries it.
        saveDebouncer.flush()
        hydrate()
        var dict = cache ?? [:]
        var order = orderCache ?? []
        var replacements: [String: String] = [:]

        for key in dict.keys {
            guard let newKey = PositionKey.replacingSourcePath(
                in: key,
                from: oldPath,
                to: newPath
            ) else { continue }
            replacements[key] = newKey
        }
        guard !replacements.isEmpty else { return }

        for (oldKey, newKey) in replacements {
            let value = dict.removeValue(forKey: oldKey)
            if dict[newKey] == nil { dict[newKey] = value }
        }
        order = order.map { replacements[$0] ?? $0 }
        var seen: Set<String> = []
        order = order.filter { seen.insert($0).inserted && dict[$0] != nil }

        cache = dict
        orderCache = order
        defaults.set(dict, forKey: positionsKey)
        defaults.set(order, forKey: orderKey)
    }

    private func writeNow(key: String, fileIdentityKey: String?, pageIndex: Int) {
        pending = nil
        hydrate()
        guard var dict = cache, var order = orderCache else { return }
        // Release the mirrors while editing so the local copies are uniquely
        // referenced and mutate in place — no per-write copy of up to
        // `maxEntries` keys.
        cache = nil
        orderCache = nil

        dict[key] = pageIndex
        if let fid = fileIdentityKey {
            dict[fid] = pageIndex
        }

        // Promote the touched keys to the front (most-recently-used). Paging
        // through one book re-touches the keys already there, so skip the
        // O(n) reshuffle in that common case.
        let touched = [key, fileIdentityKey].compactMap { $0 }
        if !order.starts(with: touched) {
            order.removeAll { touched.contains($0) }
            order.insert(contentsOf: touched, at: 0)
        }

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
        // shouldn't — `hydrate` seeds every dict key), drop arbitrary
        // extras so the cap is always honored.
        if dict.count > maxEntries {
            for extra in dict.keys.shuffled().prefix(dict.count - maxEntries) {
                dict.removeValue(forKey: extra)
            }
        }
    }

    /// The persisted value for `key`, with the pending debounced write
    /// applied on top.
    private func storedIndex(forKey key: String) -> Int? {
        if let pending, pending.key == key || pending.fileIdentityKey == key {
            return pending.pageIndex
        }
        return loaded()[key]
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

    /// Hydrate both mirrors. The MRU order is reconciled against the dict
    /// once, here: any dict key without a recorded position in the order list
    /// (entries that predate order tracking, or a direct defaults write) is
    /// appended so it's still an eviction candidate but ranks below anything
    /// explicitly touched; stale order entries no longer in the dict are
    /// dropped. Every later write keeps the two in step itself.
    private func hydrate() {
        let dict = loaded()
        guard orderCache == nil else { return }
        var order = defaults.array(forKey: orderKey) as? [String] ?? []
        var known: Set<String> = []
        order.removeAll { dict[$0] == nil || !known.insert($0).inserted }
        order.append(contentsOf: dict.keys.filter { !known.contains($0) })
        orderCache = order
    }
}
