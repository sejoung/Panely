import CryptoKit
import Foundation

nonisolated protocol ExtractionCacheManaging: Sendable {
    var cacheBudgetBytes: UInt64 { get }
    func cacheRoot() -> URL
    func isCacheURL(_ url: URL) -> Bool
    func cacheKey(for url: URL) -> String?
    func cachedEntry(forKey key: String) -> URL?
    func makeCachedCandidate(forKey key: String) -> URL
    func enforceBudget(excluding activeURL: URL?)
    func cacheSizeBytes(in root: URL, excluding activeURL: URL?) -> UInt64
    func clearCache(in root: URL, excluding activeURL: URL?) -> UInt64
}

extension ExtractionCacheManaging {
    /// Convenience for the no-active-book case (e.g. startup cleanup).
    func enforceBudget() { enforceBudget(excluding: nil) }
}

nonisolated struct LiveExtractionCacheManager: ExtractionCacheManaging {
    let cacheBudgetBytes = ExtractionCacheStore.cacheBudgetBytes

    func cacheRoot() -> URL {
        ExtractionCacheStore.cacheRoot()
    }

    func isCacheURL(_ url: URL) -> Bool {
        ExtractionCacheStore.isCacheURL(url)
    }

    func cacheKey(for url: URL) -> String? {
        ExtractionCacheStore.cacheKey(for: url)
    }

    func cachedEntry(forKey key: String) -> URL? {
        ExtractionCacheStore.cachedEntry(forKey: key)
    }

    func makeCachedCandidate(forKey key: String) -> URL {
        ExtractionCacheStore.makeCachedCandidate(forKey: key)
    }

    func enforceBudget(excluding activeURL: URL?) {
        ExtractionCacheStore.enforceBudget(excluding: activeURL)
    }

    func cacheSizeBytes(in root: URL, excluding activeURL: URL?) -> UInt64 {
        ExtractionCacheStore.cacheSizeBytes(in: root, excluding: activeURL)
    }

    func clearCache(in root: URL, excluding activeURL: URL?) -> UInt64 {
        ExtractionCacheStore.clearCache(in: root, excluding: activeURL)
    }
}

nonisolated enum ExtractionCacheStore {
    static let cacheBudgetBytes: UInt64 = 10 * 1024 * 1024 * 1024

    private static let cacheRootName = "panely-extraction-cache"

    static func cacheKey(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }

        let mtimeMillis = Int64(mtime.timeIntervalSince1970 * 1000)
        let composite = "\(path)|\(size)|\(mtimeMillis)"
        let digest = SHA256.hash(data: Data(composite.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func cachedEntry(forKey key: String) -> URL? {
        let candidate = cachedURL(forKey: key)
        guard FileManager.default.fileExists(atPath: candidate.path),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: candidate.path),
              !contents.isEmpty
        else { return nil }

        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: candidate.path
        )
        return candidate
    }

    static func makeCachedCandidate(forKey key: String) -> URL {
        let url = cachedURL(forKey: key)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return url
    }

    static func enforceBudget(
        limit: UInt64 = cacheBudgetBytes,
        excluding activeURL: URL? = nil,
        in root: URL = cacheRoot()
    ) {
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
            return Entry(url: url, mtime: mtime, size: measuredDirectorySize(at: url, in: root))
        }

        let total = measured.reduce(UInt64(0)) { saturatedAdd($0, $1.size) }
        guard total > limit else { return }

        // Never evict the cache entry for the book that's currently open —
        // deleting files out from under an in-progress read would break it.
        let excluded = cacheEntryContaining(activeURL, in: root)?.standardizedFileURL

        var remaining = total
        var removedAny = false
        for entry in measured.sorted(by: { $0.mtime < $1.mtime }) {
            if remaining <= limit { break }
            if entry.url.standardizedFileURL == excluded { continue }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                removeCachedSize(for: entry.url, in: root)
                removedAny = true
            }
            remaining = remaining > entry.size ? remaining - entry.size : 0
        }
        removeSizeCacheRootIfEmpty(in: root)
        if removedAny {
            NotificationCenter.default.post(name: .panelyExtractionCacheDidChange, object: nil)
        }
    }

    static func cacheSizeBytes(
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
            return saturatedAdd(total, measuredDirectorySize(at: entry, in: root))
        }
    }

    @discardableResult
    static func clearCache(
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
            let size = measuredDirectorySize(at: entry, in: root)
            if (try? fm.removeItem(at: entry)) != nil {
                removeCachedSize(for: entry, in: root)
                removed = saturatedAdd(removed, size)
            }
        }
        removeSizeCacheRootIfEmpty(in: root)
        if removed > 0 {
            NotificationCenter.default.post(name: .panelyExtractionCacheDidChange, object: nil)
        }
        return removed
    }

    static func cacheRoot() -> URL {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(cacheRootName, isDirectory: true)
    }

    static func isCacheURL(_ url: URL) -> Bool {
        url.standardizedFileURL.path
            .hasPrefix(cacheRoot().standardizedFileURL.path + "/")
    }

    private static func cachedURL(forKey key: String) -> URL {
        cacheRoot().appendingPathComponent(key, isDirectory: true)
    }

    private static func cacheEntryContaining(_ activeURL: URL?, in root: URL) -> URL? {
        guard let activeURL,
              // Non-empty: the active URL must be strictly under the cache root
              // (the root itself is not a cache entry).
              let relative = root.relativeSubpath(to: activeURL),
              !relative.isEmpty,
              let entryName = relative.split(separator: "/", maxSplits: 1).first
        else { return nil }
        return root.appendingPathComponent(String(entryName), isDirectory: true)
    }

    private static func measuredDirectorySize(at entry: URL, in root: URL) -> UInt64 {
        if let cached = cachedDirectorySize(at: entry, in: root) {
            return cached
        }
        let size = directorySize(at: entry)
        writeCachedSize(size, for: entry, in: root)
        return size
    }

    private static func cachedDirectorySize(at entry: URL, in root: URL) -> UInt64? {
        guard let cached = try? String(contentsOf: sizeCacheURL(for: entry, in: root), encoding: .utf8)
        else { return nil }

        let parts = cached.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let cachedMtime = TimeInterval(parts[0]),
              let cachedSize = UInt64(parts[1]),
              let currentMtime = entryModificationTime(entry)
        else { return nil }

        return abs(cachedMtime - currentMtime) < 0.001 ? cachedSize : nil
    }

    private static func writeCachedSize(_ size: UInt64, for entry: URL, in root: URL) {
        guard let mtime = entryModificationTime(entry) else { return }
        let cacheRoot = sizeCacheRoot(in: root)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try? "\(mtime)\n\(size)".write(
            to: sizeCacheURL(for: entry, in: root),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func removeCachedSize(for entry: URL, in root: URL) {
        try? FileManager.default.removeItem(at: sizeCacheURL(for: entry, in: root))
    }

    private static func removeSizeCacheRootIfEmpty(in root: URL) {
        let cacheRoot = sizeCacheRoot(in: root)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil
        ), contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    private static func entryModificationTime(_ entry: URL) -> TimeInterval? {
        (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?
            .timeIntervalSinceReferenceDate
    }

    private static func sizeCacheURL(for entry: URL, in root: URL) -> URL {
        sizeCacheRoot(in: root).appendingPathComponent(entry.lastPathComponent + ".size")
    }

    private static func sizeCacheRoot(in root: URL) -> URL {
        root.appendingPathComponent(".panely-size-cache", isDirectory: true)
    }

    private static func directorySize(at url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let entry as URL in enumerator {
            // Cooperative cancellation: when run inside a cancellable scan
            // task (StorageSettingsView), abandon the walk early instead of
            // grinding through a huge cache the caller no longer cares about.
            if Task.isCancelled { break }
            let values = try? entry.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileSizeKey,
            ])
            let size = UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            total = saturatedAdd(total, size)
        }
        return total
    }

    private static func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}

extension Notification.Name {
    nonisolated static let panelyExtractionCacheDidChange = Notification.Name("panelyExtractionCacheDidChange")
}
