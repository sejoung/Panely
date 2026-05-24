import Foundation

/// Lifecycle of the temp directory used to extract zip-in-zip archives.
/// Session directories are removed on book switch and stale sessions are
/// swept on startup. Persistent extraction cache policy lives in
/// `ExtractionCacheStore` behind the injected `ExtractionCacheManaging`
/// service.
@MainActor
final class ReaderTempDirectory {
    nonisolated private static let sessionDirPrefix = "panely-"

    private let extractionCache: any ExtractionCacheManaging
    var url: URL?

    var isActive: Bool { url != nil }

    init(extractionCache: any ExtractionCacheManaging = LiveExtractionCacheManager()) {
        self.extractionCache = extractionCache
    }

    func adopt(_ dir: URL) {
        url = dir
    }

    func cleanup() {
        guard let dir = url else { return }
        if !extractionCache.isCacheURL(dir) {
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

    nonisolated static func cleanupStaleEntries(
        extractionCache: any ExtractionCacheManaging = LiveExtractionCacheManager()
    ) {
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

        extractionCache.enforceBudget()
    }
}
