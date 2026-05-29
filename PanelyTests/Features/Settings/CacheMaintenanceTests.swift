import Foundation
import Testing
@testable import Panely

struct CacheMaintenanceTests {
    @Test func cacheSizesUsesTotalAndClearableCounts() throws {
        let maintenance = CacheMaintenance()
        let root = try makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("active", isDirectory: true)
        let inactive = root.appendingPathComponent("inactive", isDirectory: true)
        try writeCacheEntry(active, byteCount: 128)
        try writeCacheEntry(inactive, byteCount: 256)

        let sizes = maintenance.cacheSizes(
            in: root,
            excluding: active.appendingPathComponent("blob")
        )

        #expect(sizes.total >= sizes.clearable)
        #expect(sizes.clearable > 0)
    }

    @Test func clearExtractionCachePreservesExcludedEntry() throws {
        let maintenance = CacheMaintenance()
        let root = try makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("active", isDirectory: true)
        let inactive = root.appendingPathComponent("inactive", isDirectory: true)
        try writeCacheEntry(active, byteCount: 128)
        try writeCacheEntry(inactive, byteCount: 256)

        let removed = maintenance.clearExtractionCache(
            in: root,
            excluding: active.appendingPathComponent("blob")
        )

        #expect(removed > 0)
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(FileManager.default.fileExists(atPath: inactive.path) == false)
    }

    @Test func formattedBytesUsesBinaryStyle() {
        #expect(CacheMaintenance().formattedBytes(1024).isEmpty == false)
    }

    @Test func usesInjectedExtractionCacheManager() {
        let root = URL(fileURLWithPath: "/fake-cache", isDirectory: true)
        let maintenance = CacheMaintenance(
            extractionCache: FakeExtractionCacheManager(root: root, total: 900, clearable: 300, removed: 250)
        )

        let sizes = maintenance.cacheSizes(in: root, excluding: root.appendingPathComponent("active/blob"))

        #expect(maintenance.cacheRoot() == root)
        #expect(maintenance.cacheBudgetBytes == 1_024)
        #expect(sizes.total == 900)
        #expect(sizes.clearable == 300)
        #expect(maintenance.clearExtractionCache(excluding: nil) == 250)
    }

    private func makeCacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("paneltest-cache-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeCacheEntry(_ dir: URL, byteCount: Int) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: byteCount).write(to: dir.appendingPathComponent("blob"))
    }
}

private nonisolated struct FakeExtractionCacheManager: ExtractionCacheManaging {
    let root: URL
    let total: UInt64
    let clearable: UInt64
    let removed: UInt64

    var cacheBudgetBytes: UInt64 { 1_024 }

    func cacheRoot() -> URL { root }
    func isCacheURL(_ url: URL) -> Bool { root.isAncestor(of: url) }
    func cacheKey(for url: URL) -> String? { "fake-key" }
    func cachedEntry(forKey key: String) -> URL? { nil }
    func makeCachedCandidate(forKey key: String) -> URL {
        root.appendingPathComponent(key, isDirectory: true)
    }
    func enforceBudget(excluding activeURL: URL?) {}
    func cacheSizeBytes(in root: URL, excluding activeURL: URL?) -> UInt64 {
        activeURL == nil ? total : clearable
    }
    func clearCache(in root: URL, excluding activeURL: URL?) -> UInt64 { removed }
}
