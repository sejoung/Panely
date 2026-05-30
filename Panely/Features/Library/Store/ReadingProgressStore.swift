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
    private(set) var entries: [String: ReadingProgress] = [:]

    private var pendingSaveTask: Task<Void, Never>?
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

    func progress(for sourceURL: URL, opened openedURL: URL?, tempRoot: URL?) -> ReadingProgress? {
        let keys = PositionKey.keys(for: sourceURL, opened: openedURL, tempRoot: tempRoot)
        return progress(forKey: keys.primary, fileIdentityKey: keys.fileIdentity)
    }

    // MARK: - Recording

    /// Debounced write. Rapid repeat calls coalesce into one round-trip after
    /// ~300 ms of quiet (matches `ReaderPositionStore`).
    func record(forKey key: String, fileIdentityKey: String?, page: Int, total: Int, finished: Bool) {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.writeNow(key: key, fileIdentityKey: fileIdentityKey, page: page, total: total, finished: finished)
        }
    }

    func flushImmediately(forKey key: String, fileIdentityKey: String?, page: Int, total: Int, finished: Bool) {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
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

    private func writeNow(key: String, fileIdentityKey: String?, page: Int, total: Int, finished: Bool) {
        var dict = entries
        let progress = ReadingProgress(page: page, total: total, finished: finished, updatedAt: clock())
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
        guard dict.count > maxEntries else { return }
        let overflow = dict.count - maxEntries
        let stale = dict
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(overflow)
            .map(\.key)
        for key in stale {
            dict.removeValue(forKey: key)
        }
    }
}
