import Foundation
@testable import Panely

final class InMemoryKeyValueStore: KeyValueStoring, @unchecked Sendable {
    private var storage: [String: Any]

    init(_ storage: [String: Any] = [:]) {
        self.storage = storage
    }

    func data(forKey key: String) -> Data? {
        storage[key] as? Data
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        storage[key] as? [String: Any]
    }

    func dictionaryRepresentation() -> [String: Any] {
        storage
    }

    func set(_ value: Any?, forKey key: String) {
        storage[key] = value
    }

    func removeObject(forKey key: String) {
        storage.removeValue(forKey: key)
    }
}

final class TestExtractionCacheManager: ExtractionCacheManaging, @unchecked Sendable {
    let cacheBudgetBytes: UInt64
    private let root: URL

    init(
        root: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("paneltest-cache-root-\(UUID().uuidString)", isDirectory: true),
        cacheBudgetBytes: UInt64 = 10 * 1024 * 1024 * 1024
    ) {
        self.root = root
        self.cacheBudgetBytes = cacheBudgetBytes
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func cacheRoot() -> URL {
        root
    }

    func isCacheURL(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    func cacheKey(for url: URL) -> String? {
        ExtractionCacheStore.cacheKey(for: url)
    }

    func cachedEntry(forKey key: String) -> URL? {
        let candidate = cacheRoot().appendingPathComponent(key, isDirectory: true)
        guard FileManager.default.fileExists(atPath: candidate.path),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: candidate.path),
              !contents.isEmpty
        else { return nil }

        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: candidate.path)
        return candidate
    }

    func makeCachedCandidate(forKey key: String) -> URL {
        let url = cacheRoot().appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    func enforceBudget() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var measured: [(url: URL, modified: Date, size: UInt64)] = []
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            measured.append((entry, modified, directorySize(at: entry)))
        }

        var remaining = measured.reduce(UInt64(0)) { $0 &+ $1.size }
        for entry in measured.sorted(by: { $0.modified < $1.modified }) {
            if remaining <= cacheBudgetBytes { break }
            try? FileManager.default.removeItem(at: entry.url)
            remaining = remaining > entry.size ? remaining - entry.size : 0
        }
    }

    func cacheSizeBytes(in root: URL, excluding activeURL: URL?) -> UInt64 {
        ExtractionCacheStore.cacheSizeBytes(in: root, excluding: activeURL)
    }

    func clearCache(in root: URL, excluding activeURL: URL?) -> UInt64 {
        ExtractionCacheStore.clearCache(in: root, excluding: activeURL)
    }

    private func directorySize(at url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
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
            total &+= UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}

nonisolated struct TestSecurityScopedBookmarkResolver: SecurityScopedBookmarking {
    func data(for url: URL) throws -> Data {
        Data(url.absoluteString.utf8)
    }

    func resolve(_ bookmarkData: Data) -> SecurityScopedBookmark.Resolution? {
        guard let raw = String(data: bookmarkData, encoding: .utf8),
              let url = URL(string: raw)
        else { return nil }
        return SecurityScopedBookmark.Resolution(url: url, isStale: false)
    }

    func refreshedData(for url: URL) -> Data? {
        try? data(for: url)
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}

nonisolated struct TestLibraryTreeLoader: LibraryTreeLoading {
    func loadTree(from url: URL, maxDepth: Int) async -> [FileNode] {
        await FileNode.loadTree(from: url, maxDepth: maxDepth)
    }
}

nonisolated struct TestSystemSettings: SystemSettingsReading {
    var windowDoubleClickAction: WindowDoubleClickAction = .zoom
}

@MainActor
func makeTestDependencies(
    keyValueStore: InMemoryKeyValueStore = InMemoryKeyValueStore(),
    extractionCache: any ExtractionCacheManaging = TestExtractionCacheManager(),
    bookmarkResolver: any SecurityScopedBookmarking = TestSecurityScopedBookmarkResolver(),
    libraryTreeLoader: any LibraryTreeLoading = TestLibraryTreeLoader(),
    systemSettings: any SystemSettingsReading = TestSystemSettings()
) -> AppDependencies {
    AppDependencies(
        extractionCache: extractionCache,
        bookmarkResolver: bookmarkResolver,
        libraryTreeLoader: libraryTreeLoader,
        keyValueStore: keyValueStore,
        systemSettings: systemSettings
    )
}

@MainActor
func makeTestViewModel(
    keyValueStore: InMemoryKeyValueStore = InMemoryKeyValueStore(),
    extractionCache: any ExtractionCacheManaging = TestExtractionCacheManager()
) -> ReaderViewModel {
    ReaderViewModel(
        dependencies: makeTestDependencies(
            keyValueStore: keyValueStore,
            extractionCache: extractionCache
        )
    )
}
