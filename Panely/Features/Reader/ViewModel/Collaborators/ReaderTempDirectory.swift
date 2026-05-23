import CryptoKit
import Foundation

/// Lifecycle of the temp directory used to extract zip-in-zip archives,
/// plus a content-addressed extraction cache so the same source archive
/// only pays the extraction cost once.
///
/// Two kinds of directories are managed:
///
/// - **Session extractions** at `<tmpRoot>/panely-<uuid>/` — used when the
///   source can't be stat'd (no cache key derivable). Deleted on book
///   switch and swept on app launch if older than 10 minutes.
/// - **Cached extractions** at `<cachesRoot>/panely-extraction-cache/<key>/`
///   — keyed by SHA256 of `path|size|mtime`. Survives book switches and
///   app restarts; pruned LRU when total cache size exceeds
///   `cacheBudgetBytes`. Lives under `~/Library/Caches/` so the system can
///   purge under disk pressure without losing app state.
///
/// Kept off `ReaderViewModel` so the load pipeline doesn't carry low-level
/// path comparison and orphan-sweep code alongside its own state.
@MainActor
final class ReaderTempDirectory {
    /// Maximum total size across all `panely-extraction-cache/<key>/`
    /// entries. When extraction would push us past this, the oldest entries
    /// (by directory mtime) are removed first. 10 GB fits a handful of
    /// large zip-in-zip series without dominating a typical SSD.
    /// `nonisolated` so the background sweep can read it without hopping
    /// to the main actor.
    nonisolated static let cacheBudgetBytes: UInt64 = 10 * 1024 * 1024 * 1024

    nonisolated private static let cacheRootName = "panely-extraction-cache"
    nonisolated private static let sessionDirPrefix = "panely-"

    /// Currently active extraction root, or `nil` when no archive is open.
    /// Direct assignment is supported so tests can stage a fake root
    /// without going through extraction; production code uses
    /// `adopt(_:)` / `cleanup()`.
    var url: URL?

    /// True when the active source is being served out of an extracted
    /// directory (either session or cache).
    var isActive: Bool { url != nil }

    /// Mark `dir` as the active extraction root. Caller is responsible for
    /// having created it (via `makeSessionCandidate()` or
    /// `makeCachedCandidate(forKey:)`).
    func adopt(_ dir: URL) {
        url = dir
    }

    /// Release the active reference. Session dirs are removed from disk;
    /// cache dirs stay on disk and are managed by `enforceCacheBudget()`.
    /// Safe to call repeatedly — no-ops when nothing is active.
    func cleanup() {
        guard let dir = url else { return }
        if !Self.isCacheURL(dir) {
            try? FileManager.default.removeItem(at: dir)
        }
        url = nil
    }

    /// True when `candidate` lives inside the active extraction (either
    /// session or cache). False when no extraction is active.
    func contains(_ candidate: URL) -> Bool {
        url?.isAncestor(of: candidate) ?? false
    }

    // MARK: - Session dirs (no cache)

    /// Generate a fresh candidate path under the sandbox tmp. Used when
    /// the source can't be stat'd (so no stable cache key can be derived).
    /// The directory itself isn't created — that's the loader's job.
    static func makeSessionCandidate() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sessionDirPrefix)\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Content-addressed cache

    /// Stable cache key derived from the source archive's path + size +
    /// mtime. Same archive → same key → same extraction dir reused across
    /// launches. Edits to the source bump mtime → new key → automatic
    /// re-extraction. Returns nil when the file can't be stat'd (caller
    /// should fall back to `makeSessionCandidate()`).
    static func cacheKey(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        // Quantize mtime to milliseconds — bypasses sub-millisecond drift
        // from filesystems with higher mtime resolution that would otherwise
        // change the cache key on every metadata refresh.
        let mtimeMillis = Int64(mtime.timeIntervalSince1970 * 1000)
        let composite = "\(path)|\(size)|\(mtimeMillis)"
        let digest = SHA256.hash(data: Data(composite.utf8))
        // 16 hex chars = 64 bits. Collision probability is ~1 in 4 billion
        // for a million cache entries — comfortably more than we'll ever
        // have (budget alone caps it at low thousands).
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the cache dir for `key` iff it's present and non-empty.
    /// Touches the dir's mtime on a hit so the LRU policy treats it as
    /// most-recently-used.
    static func cachedEntry(forKey key: String) -> URL? {
        let candidate = cachedURL(forKey: key)
        guard FileManager.default.fileExists(atPath: candidate.path),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: candidate.path),
              !contents.isEmpty
        else { return nil }
        // Touch mtime so this entry sorts as "newest" for eviction.
        // Failure to touch is non-fatal — eviction will just consider this
        // entry older than it actually is, which only matters under
        // budget pressure.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: candidate.path
        )
        return candidate
    }

    /// Build the cache URL for `key` and ensure the parent
    /// `panely-extraction-cache/` directory exists. The cache dir itself
    /// isn't created — `CBZLoader.extractAll` does that.
    static func makeCachedCandidate(forKey key: String) -> URL {
        let url = cachedURL(forKey: key)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return url
    }

    /// Walk every cache entry, sum total size, and evict oldest-by-mtime
    /// until under `cacheBudgetBytes`. Safe to call repeatedly — no-op
    /// when already under budget. Cheap when the cache is small.
    nonisolated static func enforceCacheBudget() {
        let root = cacheRoot()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        struct Entry {
            let url: URL
            let mtime: Date
            let size: UInt64
        }

        let measured: [Entry] = entries.map { url in
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return Entry(url: url, mtime: mtime, size: directorySize(at: url))
        }

        let total = measured.reduce(UInt64(0)) { $0 + $1.size }
        guard total > cacheBudgetBytes else { return }

        // Oldest first → those get evicted first.
        let oldestFirst = measured.sorted { $0.mtime < $1.mtime }
        var remaining = total
        var removedAny = false
        for entry in oldestFirst {
            if remaining <= cacheBudgetBytes { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                removedAny = true
            }
            remaining = remaining > entry.size ? remaining - entry.size : 0
        }
        if removedAny {
            NotificationCenter.default.post(name: .panelyExtractionCacheDidChange, object: nil)
        }
    }

    /// Total bytes currently stored in the extraction cache. When `activeURL`
    /// points inside a cache entry, that entry can be excluded to report the
    /// bytes that are safe to clear without disrupting the open book.
    nonisolated static func cacheSizeBytes(
        in root: URL = cacheRoot(),
        excluding activeURL: URL? = nil
    ) -> UInt64 {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let excluded = cacheEntryContaining(activeURL, in: root)?.standardizedFileURL
        return entries.reduce(UInt64(0)) { total, entry in
            if entry.standardizedFileURL == excluded { return total }
            return saturatedAdd(total, directorySize(at: entry))
        }
    }

    /// Clear cached extractions while preserving the cache entry backing the
    /// currently open book, if any. Returns the approximate number of bytes
    /// removed; individual deletion failures are skipped so one bad entry
    /// doesn't block clearing the rest.
    @discardableResult
    nonisolated static func clearCache(
        in root: URL = cacheRoot(),
        excluding activeURL: URL? = nil
    ) -> UInt64 {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let excluded = cacheEntryContaining(activeURL, in: root)?.standardizedFileURL
        var removed: UInt64 = 0
        for entry in entries where entry.standardizedFileURL != excluded {
            let size = directorySize(at: entry)
            if (try? fm.removeItem(at: entry)) != nil {
                removed = saturatedAdd(removed, size)
            }
        }
        if removed > 0 {
            NotificationCenter.default.post(name: .panelyExtractionCacheDidChange, object: nil)
        }
        return removed
    }

    // MARK: - Orphan sweep (session dirs only)

    /// Sweep `panely-<uuid>` directories left behind by a prior session
    /// that crashed or was force-quit before `cleanup()` ran. A single
    /// zip-in-zip extraction can be hundreds of megabytes, and macOS only
    /// sweeps the sandbox tmp opportunistically, so leftovers accumulate.
    ///
    /// Called from `ReaderViewModel.init` on a background queue, where it
    /// races with the app's own first extraction. To avoid deleting that
    /// brand-new dir, only sweep entries whose mtime is older than
    /// `staleAge` — anything fresher belongs to a concurrent load or
    /// another running instance.
    ///
    /// Cache dirs are excluded — they live under `cacheRoot()`, not tmp,
    /// and are managed by `enforceCacheBudget()` instead.
    nonisolated static func cleanupStaleEntries() {
        let tmpRoot = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmpRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // 10 minutes is generous: even a multi-GB zip-in-zip extraction
        // typically finishes well under that, and anything older is almost
        // certainly orphaned from a prior session.
        let staleAge: TimeInterval = 10 * 60
        let cutoff = Date().addingTimeInterval(-staleAge)

        for entry in entries where entry.lastPathComponent.hasPrefix(sessionDirPrefix) {
            let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard mtime < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }

        // While we're at it, enforce the cache budget too — startup is a
        // natural time to amortise the size walk.
        enforceCacheBudget()
    }

    // MARK: - Internals

    /// Root directory holding all cached extractions. Lives under
    /// `~/Library/Caches/` (sandbox-mapped) so the system can purge under
    /// disk pressure and the cache survives reboots. Falls back to tmp if
    /// `.cachesDirectory` is unavailable — should never happen on macOS.
    nonisolated static func cacheRoot() -> URL {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(cacheRootName, isDirectory: true)
    }

    private nonisolated static func cachedURL(forKey key: String) -> URL {
        cacheRoot().appendingPathComponent(key, isDirectory: true)
    }

    private nonisolated static func isCacheURL(_ url: URL) -> Bool {
        url.standardizedFileURL.path
            .hasPrefix(cacheRoot().standardizedFileURL.path + "/")
    }

    private nonisolated static func cacheEntryContaining(_ activeURL: URL?, in root: URL) -> URL? {
        guard let activeURL else { return nil }
        let root = root.standardizedFileURL
        let active = activeURL.standardizedFileURL
        guard root.isAncestor(of: active) else { return nil }

        let rootPath = root.path
        let activePath = active.path
        guard activePath != rootPath,
              activePath.hasPrefix(rootPath + "/") else { return nil }

        let relative = String(activePath.dropFirst(rootPath.count + 1))
        guard let entryName = relative.split(separator: "/", maxSplits: 1).first else {
            return nil
        }
        return root.appendingPathComponent(String(entryName), isDirectory: true)
    }

    private nonisolated static func directorySize(at url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let entry as URL in enumerator {
            let values = try? entry.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileSizeKey,
            ])
            let size = UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            total = saturatedAdd(total, size)
        }
        return total
    }

    private nonisolated static func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}

extension Notification.Name {
    nonisolated static let panelyExtractionCacheDidChange = Notification.Name("panelyExtractionCacheDidChange")
}
