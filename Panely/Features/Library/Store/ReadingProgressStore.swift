import Foundation

/// Per-book reading progress (`page` / `total` / `finished` / `updatedAt`),
/// keyed by the stable `PositionKey` so it survives archive re-extraction.
/// Powers the sidebar's progress badges and the "Continue reading" row.
///
/// Writes are debounced and coalesced (vertical scroll fires on every page
/// change at ~60 Hz); a sync flush is provided for app termination, and the
/// pending write is also settled when the app resigns active or another
/// book's write arrives. Capped on entry count — the least-recently-updated
/// books drop out first — so a long reading history can't grow
/// `UserDefaults` without bound (mirrors the caps on `ReaderPositionStore` /
/// `PageBookmarksStore`).
@Observable
@MainActor
final class ReadingProgressStore {
    nonisolated static let storeKey = "panely.readingProgress"
    nonisolated static let maxEntries = 4000
    /// Quiet period before a debounced write lands. Every write re-encodes
    /// the whole dictionary (up to `maxEntries`) into `UserDefaults` on the
    /// main thread, so this is deliberately longer than a page-turn cadence.
    nonisolated static let saveDelay: Duration = .seconds(2)

    /// Keyed by `PositionKey`. Observed, so the sidebar re-renders its badges
    /// as soon as progress changes.
    private(set) var entries: [String: ReadingProgress] = [:] {
        didSet { revision &+= 1 }
    }
    /// Bumped on every `entries` change. Lets a reader memoize work derived
    /// from the whole dictionary and revalidate in O(1) — and still register
    /// an observation dependency — instead of re-scanning thousands of keys.
    private(set) var revision = 0
    /// Bumped only when the *set of keys* changes (a book's first record, a
    /// removal, a migration, an eviction) — not when an existing record's
    /// page moves. Lets readers cache structure derived from the keys (e.g.
    /// which records belong to which recent source) across page turns.
    @ObservationIgnored private(set) var keysRevision = 0

    /// Module-internal so tests can flush the pending write instead of
    /// waiting out the delay.
    let saveDebouncer = Debouncer(delay: ReadingProgressStore.saveDelay)
    /// Key of the write waiting in `saveDebouncer`. One debouncer serves every
    /// book, so a write for a different key must flush this one first instead
    /// of replacing it — otherwise finishing Vol 1 and immediately opening
    /// Vol 2 drops Vol 1's "finished" record.
    private var pendingKey: String?
    private let defaults: any KeyValueStoring
    private let storeKey: String
    private let maxEntries: Int
    /// Injectable clock so eviction-by-recency is deterministically testable.
    private let clock: @MainActor () -> Date

    init(
        defaults: any KeyValueStoring = LiveKeyValueStore(),
        storeKey: String = ReadingProgressStore.storeKey,
        maxEntries: Int = ReadingProgressStore.maxEntries,
        clock: @MainActor @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.storeKey = storeKey
        self.maxEntries = maxEntries
        self.clock = clock
        if let decoded = defaults.loadCodable([String: ReadingProgress].self, forKey: storeKey) {
            entries = decoded
        }
    }

    // MARK: - Lookup

    func progress(forKey key: String, fileIdentityKey: String?) -> ReadingProgress? {
        if let primary = entries[key] { return primary }
        if let fid = fileIdentityKey, let secondary = entries[fid] { return secondary }
        return nil
    }

    /// Continue Reading cares about the freshest alias. A moved file may have
    /// an older path record and a newer file-identity record until migration
    /// reconciles them.
    func mostRecentProgress(forKey key: String, fileIdentityKey: String?) -> ReadingProgress? {
        [entries[key], fileIdentityKey.flatMap { entries[$0] }]
            .compactMap { $0 }
            .max { $0.updatedAt < $1.updatedAt }
    }

    func progress(for sourceURL: URL, opened openedURL: URL?, tempRoot: URL?) -> ReadingProgress? {
        let keys = PositionKey.keys(for: sourceURL, opened: openedURL, tempRoot: tempRoot)
        return progress(forKey: keys.primary, fileIdentityKey: keys.fileIdentity)
    }

    func remove(forKey key: String, fileIdentityKey: String?) {
        // Settle the pending write first so it can't be lost (another book's)
        // or resurrect what is being changed below (this book's).
        saveDebouncer.flush()
        guard entries[key] != nil || fileIdentityKey.map({ entries[$0] != nil }) == true else { return }
        mutateEntries { dict in
            dict.removeValue(forKey: key)
            if let fileIdentityKey { dict.removeValue(forKey: fileIdentityKey) }
        }
        keysRevision &+= 1
        persist()
    }

    /// Explicitly forget every progress record addressable through a recent
    /// source. Used only by the user's "Remove from list" action; automatic
    /// availability checks never destroy history for temporarily-offline
    /// removable volumes.
    func removeEntries(forSourcePath sourcePath: String) {
        // Settle the pending write first so it can't be lost (another book's)
        // or resurrect what is being changed below (this book's).
        saveDebouncer.flush()
        let filtered = entries.filter { key, _ in
            PositionKey.replacingSourcePath(in: key, from: sourcePath, to: "") == nil
        }
        guard filtered.count != entries.count else { return }
        entries = filtered
        keysRevision &+= 1
        persist()
    }

    func migrateSourcePath(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        // Settle the pending write first so it can't be lost (another book's)
        // or resurrect what is being changed below (this book's).
        saveDebouncer.flush()
        var migrated = entries
        var changed = false
        for (key, progress) in entries {
            guard let newKey = PositionKey.replacingSourcePath(
                in: key,
                from: oldPath,
                to: newPath
            ) else { continue }
            migrated.removeValue(forKey: key)
            if let existing = migrated[newKey], existing.updatedAt > progress.updatedAt {
                // Keep the freshest side when old and new paths both exist.
            } else {
                migrated[newKey] = progress
            }
            changed = true
        }
        guard changed else { return }
        entries = migrated
        keysRevision &+= 1
        persist()
    }

    /// Completion is sticky so moving back from the final page does not make a
    /// finished book reappear in Continue Reading. An explicit restart calls
    /// this method to begin a fresh read.
    func resetCompletion(
        forKey key: String,
        fileIdentityKey: String?,
        page: Int,
        total: Int
    ) {
        saveDebouncer.flush()
        let progress = ReadingProgress(
            page: page,
            total: total,
            finished: false,
            updatedAt: clock()
        )
        store(progress, forKey: key, fileIdentityKey: fileIdentityKey)
    }

    // MARK: - Recording

    /// Debounced write. Rapid repeat calls coalesce into one round-trip after
    /// `saveDelay` of quiet (matches `ReaderPositionStore`).
    func record(forKey key: String, fileIdentityKey: String?, page: Int, total: Int, finished: Bool) {
        settlePendingWrite(unlessFor: key)
        pendingKey = key
        saveDebouncer.schedule { [weak self] in
            self?.writeNow(key: key, fileIdentityKey: fileIdentityKey, page: page, total: total, finished: finished)
        }
    }

    func flushImmediately(forKey key: String, fileIdentityKey: String?, page: Int, total: Int, finished: Bool) {
        settlePendingWrite(unlessFor: key)
        saveDebouncer.cancel()
        writeNow(key: key, fileIdentityKey: fileIdentityKey, page: page, total: total, finished: finished)
    }

    func record(for sourceURL: URL, opened openedURL: URL?, tempRoot: URL?, page: Int, total: Int, finished: Bool) {
        let keys = PositionKey.keys(for: sourceURL, opened: openedURL, tempRoot: tempRoot)
        record(forKey: keys.primary, fileIdentityKey: keys.fileIdentity, page: page, total: total, finished: finished)
    }

    func flushImmediately(for sourceURL: URL, opened openedURL: URL?, tempRoot: URL?, page: Int, total: Int, finished: Bool) {
        let keys = PositionKey.keys(for: sourceURL, opened: openedURL, tempRoot: tempRoot)
        flushImmediately(forKey: keys.primary, fileIdentityKey: keys.fileIdentity, page: page, total: total, finished: finished)
    }

    // MARK: - Internals

    /// A pending write for `key` is about to be superseded and can be dropped;
    /// one for any other key is that record's last word and must land.
    private func settlePendingWrite(unlessFor key: String) {
        if pendingKey != key { saveDebouncer.flush() }
    }

    private func writeNow(key: String, fileIdentityKey: String?, page: Int, total: Int, finished: Bool) {
        let existing = entries[key] ?? fileIdentityKey.flatMap { entries[$0] }
        // Preserve completion while the underlying page count is unchanged.
        // If the book is replaced with a different-length edition, recompute
        // from its new end rather than carrying a stale completion forever.
        let effectiveFinished = existing?.total == total
            ? (existing?.finished == true || finished)
            : finished
        let progress = ReadingProgress(
            page: page,
            total: total,
            finished: effectiveFinished,
            updatedAt: clock()
        )
        store(progress, forKey: key, fileIdentityKey: fileIdentityKey)
    }

    /// Write `progress` under both keys in place — one `entries` mutation
    /// (one revision bump) and no copy of the whole dictionary — then evict
    /// and persist.
    private func store(_ progress: ReadingProgress, forKey key: String, fileIdentityKey: String?) {
        // Only a new key can change the key set (eviction runs only once a
        // new key pushes the count over the cap).
        let addsKey = entries[key] == nil
            || fileIdentityKey.map { entries[$0] == nil } == true
        let maxEntries = maxEntries
        mutateEntries { dict in
            dict[key] = progress
            if let fid = fileIdentityKey {
                dict[fid] = progress
            }
            // Drop the least-recently-updated entries until back under the cap.
            dict.capByRecency(to: maxEntries) { $0.updatedAt }
        }
        if addsKey { keysRevision &+= 1 }
        persist()
    }

    /// Mutates `entries` through its `_modify` accessor, so the dictionary
    /// is changed in place rather than copied, and observers see one change.
    private func mutateEntries(_ body: (inout [String: ReadingProgress]) -> Void) {
        body(&entries)
    }

    private func persist() {
        defaults.saveCodable(entries, forKey: storeKey)
    }
}
