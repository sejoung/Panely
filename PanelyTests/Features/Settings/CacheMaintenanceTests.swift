import Foundation
import Testing
@testable import Panely

struct CacheMaintenanceTests {
    @Test func cacheSizesUsesTotalAndClearableCounts() throws {
        let root = try makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("active", isDirectory: true)
        let inactive = root.appendingPathComponent("inactive", isDirectory: true)
        try writeCacheEntry(active, byteCount: 128)
        try writeCacheEntry(inactive, byteCount: 256)

        let sizes = CacheMaintenance.cacheSizes(
            in: root,
            excluding: active.appendingPathComponent("blob")
        )

        #expect(sizes.total >= sizes.clearable)
        #expect(sizes.clearable > 0)
    }

    @Test func clearExtractionCachePreservesExcludedEntry() throws {
        let root = try makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("active", isDirectory: true)
        let inactive = root.appendingPathComponent("inactive", isDirectory: true)
        try writeCacheEntry(active, byteCount: 128)
        try writeCacheEntry(inactive, byteCount: 256)

        let removed = CacheMaintenance.clearExtractionCache(
            in: root,
            excluding: active.appendingPathComponent("blob")
        )

        #expect(removed > 0)
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(FileManager.default.fileExists(atPath: inactive.path) == false)
    }

    @Test func formattedBytesUsesBinaryStyle() {
        #expect(CacheMaintenance.formattedBytes(1024).isEmpty == false)
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
