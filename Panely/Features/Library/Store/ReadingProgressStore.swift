import Foundation

/// Per-book reading progress (`page` / `total` / `finished` / `updatedAt`),
/// keyed by the stable `PositionKey` so it survives archive re-extraction.
/// Powers the sidebar's progress badges and the "Continue reading" row.
///
/// Writes are debounced and coalesced (vertical scroll fires on every page
/// change at ~60 Hz); a sync flush is provided for app termination. Capped on
/// entry count — the least-recently-updated books drop out first — so a long
/// reading history can't grow `UserDefaults` without bound (mirrors the caps
/// on `ReaderPositionStore` / `PageBookmarksStore`).
@Observable
@MainActor
final class ReadingProgressStore {
    nonisolated static let storeKey = "panely.readingProgress"
    nonisolated static let maxEntries = 4000

    /// Keyed by `PositionKey`. Observed, so the sidebar re-renders its badges
    /// as soon as progress changes.
    private(set) var entries: [String: ReadingProgress] = [:] {
        didSet { revision &+= 1 }
    }
    /// Bumped on every `entries` change. Lets a reader memoize work derived
    /// from the whole dictionary and revalidate in O(1) — and still register
    /// an observation dependency — instead of re-scanning thousands of keys.
    private(set) var revision = 0

    private let saveDebouncer = Debouncer()
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
        var dict = entries
        dict.removeValue(forKey: key)
        if let fileIdentityKey { dict.removeValue(forKey: fileIdentityKey) }
        guard dict != entries else { return }
        entries = dict
        defaults.saveCodable(dict, forKey: storeKey)
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
        defaults.saveCodable(filtered, forKey: storeKey)
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
        defaults.saveCodable(migrated, forKey: storeKey)
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
        var dict = entries
        let progress = ReadingProgress(
            page: page,
            total: total,
            finished: false,
            updatedAt: clock()
        )
        dict[key] = progress
        if let fileIdentityKey { dict[fileIdentityKey] = progress }
        evictIfNeeded(&dict)
        entries = dict
        defaults.saveCodable(dict, forKey: storeKey)
    }

    // MARK: - Recording

    /// Debounced write. Rapid repeat calls coalesce into one round-trip after
    /// ~300 ms of quiet (matches `ReaderPositionStore`).
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
        var dict = entries
        let existing = dict[key] ?? fileIdentityKey.flatMap { dict[$0] }
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
        dict[key] = progress
        if let fid = fileIdentityKey {
            dict[fid] = progress
        }
        evictIfNeeded(&dict)
        entries = dict
        defaults.saveCodable(dict, forKey: storeKey)
    }

    /// Drop the least-recently-updated entries until back under the cap.
    private func evictIfNeeded(_ dict: inout [String: ReadingProgress]) {
        dict.capByRecency(to: maxEntries) { $0.updatedAt }
    }
}
