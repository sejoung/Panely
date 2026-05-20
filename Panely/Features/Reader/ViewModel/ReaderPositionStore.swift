import Foundation

/// Per-book reading position memory. In-memory mirror of the positions
/// dictionary backs the hot path (vertical scroll fires `setCurrentPageFromScroll`
/// at ~60Hz) — without it, every scroll tick walked a full UserDefaults
/// dictionary. Writes are debounced and coalesced; a sync flush is provided
/// for app termination so quit-during-scroll doesn't lose progress.
@MainActor
final class ReaderPositionStore {
    static let positionsKey = "panely.positions"

    private var cache: [String: Int]?
    private var pendingSaveTask: Task<Void, Never>?

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

    private func writeNow(key: String, fileIdentityKey: String?, pageIndex: Int) {
        var dict = loaded()
        dict[key] = pageIndex
        if let fid = fileIdentityKey {
            dict[fid] = pageIndex
        }
        cache = dict
        UserDefaults.standard.set(dict, forKey: Self.positionsKey)
    }

    /// Lazy hydration. First call pays one UserDefaults syscall; subsequent
    /// calls hit the in-memory mirror until something invalidates it (we
    /// never do — the dict is mutated in place on every write).
    private func loaded() -> [String: Int] {
        if let cached = cache { return cached }
        let loaded = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Int] ?? [:]
        cache = loaded
        return loaded
    }
}
