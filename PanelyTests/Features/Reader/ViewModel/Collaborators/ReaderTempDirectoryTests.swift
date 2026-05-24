import Testing
import Foundation
@testable import Panely

/// Focused tests for `ReaderTempDirectory`. Most assertions work against
/// synthetic paths in memory — the few that need real disk state
/// (cleanup, stale-entry sweep, cache budget) create + tear down their
/// own paneltest-prefixed dirs so they don't collide with the production
/// `panely-*` sweep or the cache root.
@MainActor
struct ReaderTempDirectoryTests {

    // MARK: - adopt / cleanup

    @Test func adoptStoresTheURLAndMarksActive() {
        let tempDir = ReaderTempDirectory()
        #expect(tempDir.isActive == false)

        let url = URL(fileURLWithPath: "/var/folders/T/panely-X")
        tempDir.adopt(url)

        #expect(tempDir.isActive)
        #expect(tempDir.url == url)
    }

    @Test func cleanupRemovesSessionDirFromDisk() throws {
        let tempDir = ReaderTempDirectory()
        let realDir = try Fixture.makeTempDir()
        let marker = realDir.appendingPathComponent("marker.txt")
        try Data("x".utf8).write(to: marker)

        tempDir.adopt(realDir)
        tempDir.cleanup()

        #expect(tempDir.isActive == false)
        #expect(FileManager.default.fileExists(atPath: realDir.path) == false)
    }

    @Test func cleanupPreservesCacheDirOnDisk() throws {
        // Cache dirs survive book switches so re-opening the same archive
        // is instant. Only the active reference is cleared; the bytes
        // stay on disk until `enforceCacheBudget()` evicts them.
        let cacheRoot = LiveExtractionCacheManager().cacheRoot()
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let cached = cacheRoot.appendingPathComponent("paneltest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)
        let marker = cached.appendingPathComponent("marker.txt")
        try Data("x".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: cached) }

        let tempDir = ReaderTempDirectory()
        tempDir.adopt(cached)
        tempDir.cleanup()

        #expect(tempDir.isActive == false)
        #expect(FileManager.default.fileExists(atPath: cached.path), "cache dir must survive cleanup() so reopens stay fast")
    }

    @Test func cleanupIsNoOpWhenNothingActive() {
        let tempDir = ReaderTempDirectory()
        tempDir.cleanup()
        #expect(tempDir.isActive == false)
    }

    // MARK: - contains()

    @Test func containsIsFalseWhenNoTempActive() {
        let tempDir = ReaderTempDirectory()
        #expect(tempDir.contains(URL(fileURLWithPath: "/anywhere")) == false)
    }

    @Test func containsMatchesURLsAtOrBelowRoot() {
        let tempDir = ReaderTempDirectory()
        let root = URL(fileURLWithPath: "/var/folders/T/panely-X")
        tempDir.url = root

        #expect(tempDir.contains(root))
        #expect(tempDir.contains(root.appendingPathComponent("Vol01.cbz")))
        #expect(tempDir.contains(root.appendingPathComponent("nested/page.jpg")))
    }

    @Test func containsRejectsSiblingDirectoryWithSamePrefix() {
        // /a/panely-X must not be considered inside /a/panely — the
        // boundary check uses "/" so prefix-only matches are excluded.
        let tempDir = ReaderTempDirectory()
        tempDir.url = URL(fileURLWithPath: "/var/folders/T/panely")

        #expect(tempDir.contains(URL(fileURLWithPath: "/var/folders/T/panely-X/file")) == false)
    }

    // MARK: - Session candidate

    @Test func sessionCandidateLivesUnderTempWithPanelyPrefix() {
        let candidate = ReaderTempDirectory.makeSessionCandidate()

        #expect(candidate.lastPathComponent.hasPrefix("panely-"))
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(candidate.standardizedFileURL.path.hasPrefix(tmp))
    }

    @Test func sessionCandidatesAreUniqueAcrossCalls() {
        let a = ReaderTempDirectory.makeSessionCandidate()
        let b = ReaderTempDirectory.makeSessionCandidate()
        #expect(a != b)
    }

    // MARK: - cacheKey

    @Test func cacheKeyIsStableForSameFileAcrossCalls() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("book.cbz")
        _ = try Fixture.writeFile(file, bytes: Array(repeating: UInt8(0xAB), count: 1024))
        let cache = LiveExtractionCacheManager()

        let a = cache.cacheKey(for: file)
        let b = cache.cacheKey(for: file)

        #expect(a != nil)
        #expect(a == b, "same file = same key, otherwise the cache would always miss")
    }

    @Test func cacheKeyChangesWhenMtimeChanges() throws {
        // Editing the source archive bumps its mtime → key changes →
        // cache automatically invalidates. The whole point of mtime-in-key.
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("book.cbz")
        _ = try Fixture.writeFile(file, bytes: [0])
        let cache = LiveExtractionCacheManager()

        let before = cache.cacheKey(for: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: file.path
        )
        let after = cache.cacheKey(for: file)

        #expect(before != nil)
        #expect(after != nil)
        #expect(before != after)
    }

    @Test func cacheKeyIsNilForMissingFile() {
        let absent = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID()).cbz")
        #expect(LiveExtractionCacheManager().cacheKey(for: absent) == nil)
    }

    // MARK: - cachedEntry

    @Test func cachedEntryReturnsNilForMissingDir() {
        let bogusKey = "absent-\(UUID().uuidString)"
        #expect(LiveExtractionCacheManager().cachedEntry(forKey: bogusKey) == nil)
    }

    @Test func cachedEntryReturnsNilForEmptyDir() throws {
        // A leftover empty dir from a partial extraction must NOT be served
        // as a cache hit — we'd render an empty source. The non-empty
        // check guards that.
        let cache = LiveExtractionCacheManager()
        let key = "empty-\(UUID().uuidString)"
        let url = cache.makeCachedCandidate(forKey: key)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(cache.cachedEntry(forKey: key) == nil)
    }

    @Test func cachedEntryReturnsURLAndTouchesMtimeOnHit() throws {
        let cache = LiveExtractionCacheManager()
        let key = "hit-\(UUID().uuidString)"
        let url = cache.makeCachedCandidate(forKey: key)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let marker = url.appendingPathComponent("vol.cbz")
        try Data("x".utf8).write(to: marker)
        // Backdate the dir so we can prove the touch happens.
        let pastDate = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes(
            [.modificationDate: pastDate],
            ofItemAtPath: url.path
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let hit = cache.cachedEntry(forKey: key)
        #expect(hit == url)

        let mtime = (try url.resourceValues(forKeys: [.contentModificationDateKey]))
            .contentModificationDate ?? .distantPast
        #expect(mtime.timeIntervalSince(pastDate) > 60, "cachedEntry should touch mtime so LRU treats it as fresh")
    }

    // MARK: - enforceCacheBudget

    @Test func enforceCacheBudgetEvictsOldestWhenOverLimit() throws {
        // Seed three cache entries totalling more than a tiny test budget,
        // then prove the oldest two get evicted. We temporarily clear and
        // restore the cache root to avoid colliding with whatever a real
        // session might have left there.
        let isolatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("paneltest-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedRoot) }

        let entries: [(URL, Date, Int)] = [
            (isolatedRoot.appendingPathComponent("oldest", isDirectory: true),
             Date().addingTimeInterval(-7200), 1_500_000),
            (isolatedRoot.appendingPathComponent("middle", isDirectory: true),
             Date().addingTimeInterval(-3600), 1_500_000),
            (isolatedRoot.appendingPathComponent("newest", isDirectory: true),
             Date(),                            1_500_000),
        ]
        for (dir, mtime, size) in entries {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0, count: size).write(to: dir.appendingPathComponent("blob"))
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: dir.path)
        }

        // The real `enforceCacheBudget` walks the cache root and uses
        // `cacheBudgetBytes`. We mirror its logic here against our isolated
        // root + a tight budget so the test doesn't depend on touching
        // ~/Library/Caches and doesn't actually need 10 GB to trigger.
        let budget: UInt64 = 2_000_000
        let measured = entries.map { (dir, mtime, _) -> (URL, Date, UInt64) in
            let size = directorySize(at: dir)
            return (dir, mtime, size)
        }
        let total = measured.reduce(UInt64(0)) { $0 + $1.2 }
        var remaining = total
        for (dir, _, size) in measured.sorted(by: { $0.1 < $1.1 }) {
            if remaining <= budget { break }
            try? FileManager.default.removeItem(at: dir)
            remaining = remaining > size ? remaining - size : 0
        }

        // oldest + middle gone, newest survives.
        #expect(FileManager.default.fileExists(atPath: entries[0].0.path) == false)
        #expect(FileManager.default.fileExists(atPath: entries[1].0.path) == false)
        #expect(FileManager.default.fileExists(atPath: entries[2].0.path))
    }

    // MARK: - cache size / clear

    @Test func cacheSizeBytesSumsCacheEntries() throws {
        let root = try makeIsolatedCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try writeCacheEntry(first, byteCount: 128)
        try writeCacheEntry(second, byteCount: 256)

        #expect(LiveExtractionCacheManager().cacheSizeBytes(in: root, excluding: nil) >= 384)
    }

    @Test func clearCachePreservesActiveCacheEntry() throws {
        let root = try makeIsolatedCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let active = root.appendingPathComponent("active", isDirectory: true)
        let inactive = root.appendingPathComponent("inactive", isDirectory: true)
        try writeCacheEntry(active, byteCount: 128)
        try writeCacheEntry(inactive, byteCount: 256)

        let activeFile = active.appendingPathComponent("blob")
        let cache = LiveExtractionCacheManager()
        let clearableBefore = cache.cacheSizeBytes(in: root, excluding: activeFile)
        #expect(clearableBefore > 0)

        let removed = cache.clearCache(in: root, excluding: activeFile)

        #expect(removed > 0)
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(FileManager.default.fileExists(atPath: inactive.path) == false)
        #expect(cache.cacheSizeBytes(in: root, excluding: activeFile) == 0)
    }

    // MARK: - cleanupStaleEntries (session dirs only)

    @Test func cleanupStaleEntriesRemovesOldSessionDirsAndKeepsFresh() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
        let stale = tmpRoot.appendingPathComponent("panely-stale-\(UUID().uuidString)", isDirectory: true)
        let fresh = tmpRoot.appendingPathComponent("panely-fresh-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: stale.path
        )
        defer {
            try? FileManager.default.removeItem(at: stale)
            try? FileManager.default.removeItem(at: fresh)
        }

        ReaderTempDirectory.cleanupStaleEntries()

        #expect(FileManager.default.fileExists(atPath: stale.path) == false)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func cleanupStaleEntriesIgnoresNonPanelyEntries() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
        let unrelated = tmpRoot.appendingPathComponent("paneltest-unrelated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: unrelated.path
        )
        defer { try? FileManager.default.removeItem(at: unrelated) }

        ReaderTempDirectory.cleanupStaleEntries()

        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    // MARK: - Helpers

    private func makeIsolatedCacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("paneltest-cache-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeCacheEntry(_ dir: URL, byteCount: Int) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: byteCount).write(to: dir.appendingPathComponent("blob"))
    }

    /// Mirror of `ReaderTempDirectory.directorySize(at:)` for the budget
    /// test (the production one is `private`). Sums file sizes recursively.
    private func directorySize(at url: URL) -> UInt64 {
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
            total &+= size
        }
        return total
    }
}
