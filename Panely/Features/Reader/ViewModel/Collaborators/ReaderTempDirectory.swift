import Foundation

/// Lifecycle of the temp directory used to extract zip-in-zip archives.
/// Session directories are removed on book switch and stale sessions are
/// swept on startup. Persistent extraction cache policy lives in
/// `ExtractionCacheStore`; the static wrappers here keep older call sites
/// readable from the reader pipeline.
@MainActor
final class ReaderTempDirectory {
    nonisolated static let cacheBudgetBytes = ExtractionCacheStore.cacheBudgetBytes
    nonisolated private static let sessionDirPrefix = "panely-"

    var url: URL?

    var isActive: Bool { url != nil }

    func adopt(_ dir: URL) {
        url = dir
    }

    func cleanup() {
        guard let dir = url else { return }
        if !ExtractionCacheStore.isCacheURL(dir) {
            try? FileManager.default.removeItem(at: dir)
        }
        url = nil
    }

    func contains(_ candidate: URL) -> Bool {
        url?.isAncestor(of: candidate) ?? false
    }

    static func makeSessionCandidate() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sessionDirPrefix)\(UUID().uuidString)", isDirectory: true)
    }

    static func cacheKey(for url: URL) -> String? {
        ExtractionCacheStore.cacheKey(for: url)
    }

    static func cachedEntry(forKey key: String) -> URL? {
        ExtractionCacheStore.cachedEntry(forKey: key)
    }

    static func makeCachedCandidate(forKey key: String) -> URL {
        ExtractionCacheStore.makeCachedCandidate(forKey: key)
    }

    nonisolated static func enforceCacheBudget() {
        ExtractionCacheStore.enforceBudget()
    }

    nonisolated static func cacheSizeBytes(
        in root: URL = cacheRoot(),
        excluding activeURL: URL? = nil
    ) -> UInt64 {
        ExtractionCacheStore.cacheSizeBytes(in: root, excluding: activeURL)
    }

    @discardableResult
    nonisolated static func clearCache(
        in root: URL = cacheRoot(),
        excluding activeURL: URL? = nil
    ) -> UInt64 {
        ExtractionCacheStore.clearCache(in: root, excluding: activeURL)
    }

    nonisolated static func cacheRoot() -> URL {
        ExtractionCacheStore.cacheRoot()
    }

    nonisolated static func cleanupStaleEntries() {
        let tmpRoot = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmpRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let staleAge: TimeInterval = 10 * 60
        let cutoff = Date().addingTimeInterval(-staleAge)

        for entry in entries where entry.lastPathComponent.hasPrefix(sessionDirPrefix) {
            let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard mtime < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }

        ExtractionCacheStore.enforceBudget()
    }
}
