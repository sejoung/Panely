import CryptoKit
import Foundation

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

    static func enforceBudget(limit: UInt64 = cacheBudgetBytes) {
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
        guard total > limit else { return }

        var remaining = total
        var removedAny = false
        for entry in measured.sorted(by: { $0.mtime < $1.mtime }) {
            if remaining <= limit { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                removedAny = true
            }
            remaining = remaining > entry.size ? remaining - entry.size : 0
        }
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
            return saturatedAdd(total, directorySize(at: entry))
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

    private static func directorySize(at url: URL) -> UInt64 {
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

    private static func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}

extension Notification.Name {
    nonisolated static let panelyExtractionCacheDidChange = Notification.Name("panelyExtractionCacheDidChange")
}
