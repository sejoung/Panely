import Testing
import AppKit
import Foundation
import ZIPFoundation
import zlib
@testable import Panely

/// Pins the behaviour the reader's loading performance depends on: work that
/// used to be repeated or left running after nobody wanted it.
@MainActor
struct ReaderInFlightDecodesTests {
    private let sample = NSImage(size: NSSize(width: 1, height: 1))

    /// Lets the test decide when a decode finishes.
    private final class Gate {
        var starts = 0
        var wasCancelled = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            starts += 1
            await withCheckedContinuation { continuation = $0 }
            wasCancelled = Task.isCancelled
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func decode(_ gate: Gate) -> @MainActor () async throws -> NSImage {
        let image = sample
        return {
            await gate.wait()
            try Task.checkCancellation()
            return image
        }
    }

    @Test func concurrentRequestsShareOneDecode() async throws {
        let decodes = ReaderInFlightDecodes()
        let gate = Gate()
        let work = decode(gate)
        let first = Task { try await decodes.image(forID: "p", decode: work) }
        let second = Task { try await decodes.image(forID: "p", decode: work) }

        try await waitUntil { gate.starts == 1 }
        await Task.yield()
        gate.open()

        let a = try await first.value
        let b = try await second.value
        #expect(a === b)
        #expect(gate.starts == 1)
        #expect(decodes.activeCount == 0)
    }

    /// A superseded preload must not take the visible page's decode with it.
    @Test func cancellingOneCallerKeepsTheDecodeForTheOther() async throws {
        let decodes = ReaderInFlightDecodes()
        let gate = Gate()
        let work = decode(gate)
        let preload = Task { try await decodes.image(forID: "p", decode: work) }
        let visible = Task { try await decodes.image(forID: "p", decode: work) }
        try await waitUntil { gate.starts == 1 }

        preload.cancel()
        // The cancellation reaches the coalescer through a main-actor hop.
        try await Task.sleep(for: .milliseconds(20))
        gate.open()

        let image = try await visible.value
        #expect(image === sample)
        #expect(gate.wasCancelled == false)
    }

    @Test func cancellingEveryCallerStopsTheDecodeAndAllowsARestart() async throws {
        let decodes = ReaderInFlightDecodes()
        let gate = Gate()
        let only = Task { try await decodes.image(forID: "p", decode: decode(gate)) }
        try await waitUntil { gate.starts == 1 }

        only.cancel()
        try await waitUntil { decodes.activeCount == 0 }
        gate.open()
        await #expect(throws: CancellationError.self) { try await only.value }
        #expect(gate.wasCancelled)

        // Nothing joins the dying task: a new request gets its own decode.
        let again = Gate()
        let next = Task { try await decodes.image(forID: "p", decode: decode(again)) }
        try await waitUntil { again.starts == 1 }
        again.open()
        let image = try await next.value
        #expect(image === sample)
    }

    /// The order a scrolled batch replacement really produces: the old caller's
    /// cancellation lands before the new one has asked.
    @Test func holdKeepsADecodeAliveAcrossABatchReplacement() async throws {
        let decodes = ReaderInFlightDecodes()
        let gate = Gate()
        let work = decode(gate)
        let old = Task { try await decodes.image(forID: "p", decode: work) }
        try await waitUntil { gate.starts == 1 }

        let held = decodes.hold(ids: ["p", "not decoding"])
        old.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(decodes.activeCount == 1)

        let replacement = Task { try await decodes.image(forID: "p", decode: work) }
        await Task.yield()
        decodes.release(held)
        gate.open()

        let image = try await replacement.value
        #expect(image === sample)
        #expect(gate.starts == 1)
        #expect(gate.wasCancelled == false)
    }

    @Test func failureReachesEveryCallerAndIsNotRemembered() async throws {
        let decodes = ReaderInFlightDecodes()
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await decodes.image(forID: "p") { throw Boom() }
        }
        #expect(decodes.activeCount == 0)
    }
}

@MainActor
struct ReaderLoadOrderTests {
    @Test func preloadGoesForwardFirstThenBackNearestFirst() {
        #expect(ReaderImageLoader.preloadIndices(pageIndex: 10, step: 1, pageCount: 100) == [11, 12, 9, 8])
        #expect(ReaderImageLoader.preloadIndices(pageIndex: 10, step: 2, pageCount: 100) == [12, 13, 14, 15, 9, 8, 7, 6])
    }

    @Test func preloadStaysInsideTheBook() {
        #expect(ReaderImageLoader.preloadIndices(pageIndex: 0, step: 1, pageCount: 3) == [1, 2])
        #expect(ReaderImageLoader.preloadIndices(pageIndex: 2, step: 1, pageCount: 3) == [1, 0])
        #expect(ReaderImageLoader.preloadIndices(pageIndex: 0, step: 2, pageCount: 2) == [])
        #expect(ReaderImageLoader.preloadIndices(pageIndex: 0, step: 1, pageCount: 0) == [])
    }

    @Test func batchesDecodeOnScreenPagesFirst() {
        let order = ReaderVerticalImageWindow.visibleFirst([3, 4, 5, 6, 7, 8, 9], visibleRange: 5..<7)
        #expect(Array(order.prefix(2)) == [5, 6])
        #expect(Set(order) == [3, 4, 5, 6, 7, 8, 9])
        #expect(Array(order.dropFirst(2)) == [4, 7, 3, 8, 9])
    }
}

struct FolderLoaderSignatureTests {
    /// Page ids key the persisted translation cache: the signature from the
    /// directory listing has to match the `stat` one exactly, or every saved
    /// translation of a folder book is silently lost.
    @Test func prefetchedIDsMatchStatDerivedIDs() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<200 {
            let url = dir.appendingPathComponent("\(i).jpg")
            try Data(repeating: 1, count: i).write(to: url)
            var times = [
                timespec(tv_sec: 1_600_000_000, tv_nsec: 0),
                timespec(tv_sec: 1_600_000_000 + i * 977, tv_nsec: (i * 7_654_321) % 1_000_000_000),
            ]
            #expect(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
        }

        let source = try FolderLoader.load(from: dir)
        #expect(source.pages.count == 200)
        for page in source.pages {
            guard case .file(let url) = page.source else {
                Issue.record("expected a file page")
                continue
            }
            #expect(page.id == ComicPage(source: .file(url), displayName: "").id)
        }
    }
}

struct ThumbnailSizingTests {
    @Test func portraitPageFillsTheCellWithoutExcess() {
        let side = ThumbnailLoader.thumbnailLongSide(pixelSize: CGSize(width: 2000, height: 3000), maxPixelSize: 336)
        #expect(side == 336) // 224 px wide at 2:3 — not the old fixed 480
    }

    @Test func landscapePageNeedsOnlyTheCellWidth() {
        #expect(ThumbnailLoader.thumbnailLongSide(pixelSize: CGSize(width: 3000, height: 2000), maxPixelSize: 336) == 224)
    }

    /// `ThumbnailSidebar` clamps a cell at 3:1; a longer strip stops gaining.
    @Test func tallStripIsCapped() {
        #expect(ThumbnailLoader.thumbnailLongSide(pixelSize: CGSize(width: 800, height: 2400), maxPixelSize: 336) == 672)
        #expect(ThumbnailLoader.thumbnailLongSide(pixelSize: CGSize(width: 800, height: 12000), maxPixelSize: 336) == 672)
    }

    @Test func unknownSizeAssumesAPortraitPage() {
        #expect(ThumbnailLoader.thumbnailLongSide(pixelSize: nil, maxPixelSize: 336) == 336)
    }
}

struct ArchiveExtractionCancellationTests {
    @Test func cancelledExtractionThrowsCancellationAndLeavesNothingBehind() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let zipURL = try ZIPArchiveIndexEquivalenceTests.makeMixedArchive(in: workDir)
        let dest = workDir.appendingPathComponent("out", isDirectory: true)

        let task = Task {
            // Starts already cancelled, whichever way the race goes.
            while !Task.isCancelled { await Task.yield() }
            try await ArchiveLoader.extractAll(from: zipURL, to: dest)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func uncancelledExtractionStillCompletes() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let content = workDir.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Fixture.makePNG(width: 4, height: 4).write(to: content.appendingPathComponent("1.png"))
        let zipURL = workDir.appendingPathComponent("book.zip")
        try FileManager.default.zipItem(at: content, to: zipURL, shouldKeepParent: false)
        let dest = workDir.appendingPathComponent("out", isDirectory: true)

        try await ArchiveLoader.extractAll(from: zipURL, to: dest)

        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("1.png").path))
    }
}

/// Serialized and deliberately small: an entry takes ~45 ms in a debug build,
/// under a process-wide lock whose waiters each park a thread of the concurrency
/// pool. A 300-entry version of these held it long enough to stall every other
/// async test in the run into timeouts.
@Suite(.serialized)
struct RARPerformanceTests {
    /// Same contract as the real cache, rooted in a temp dir.
    private struct TempCache: ExtractionCacheManaging {
        let root: URL
        var cacheBudgetBytes: UInt64 { .max }
        func cacheRoot() -> URL { root }
        func isCacheURL(_ url: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") }
        func cacheKey(for url: URL) -> String? { "key" }
        func cachedEntry(forKey key: String) -> URL? {
            let dir = root.appendingPathComponent(key, isDirectory: true)
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return contents.isEmpty ? nil : dir
        }
        func makeCachedCandidate(forKey key: String) -> URL {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root.appendingPathComponent(key, isDirectory: true)
        }
        func enforceBudget(excluding activeURL: URL?) {}
        func cacheSizeBytes(in root: URL, excluding activeURL: URL?) -> UInt64 { 0 }
        func clearCache(in root: URL, excluding activeURL: URL?) -> UInt64 { 0 }
    }

    /// Proven by changing the cached bytes: a re-extraction would restore them.
    @Test func reopeningASolidArchiveServesTheCachedExtraction() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar5-solid.cbr", in: workDir)
        let cache = TempCache(root: workDir.appendingPathComponent("cache", isDirectory: true))

        var first: RARArchiveReader? = try RARArchiveReader(url: url, extractionCache: cache)
        _ = try await first?.loadData(at: "01.png")
        first = nil

        let cached = cache.root.appendingPathComponent("key/01.png")
        #expect(FileManager.default.fileExists(atPath: cached.path), "the reader's deinit must keep a cached tree")
        try Data("from the cache".utf8).write(to: cached)

        let second = try RARArchiveReader(url: url, extractionCache: cache)
        let data = try await second.loadData(at: "01.png")
        #expect(data == Data("from the cache".utf8))
    }

    /// The budget sweep or Clear Cache can remove the tree under an open book.
    @Test func solidArchiveReExtractsWhenTheCacheEntryIsEvicted() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar5-solid.cbr", in: workDir)
        let cache = TempCache(root: workDir.appendingPathComponent("cache", isDirectory: true))

        let reader = try RARArchiveReader(url: url, extractionCache: cache)
        let before = try await reader.loadData(at: "10.png")
        try FileManager.default.removeItem(at: cache.root.appendingPathComponent("key"))

        let after = try await reader.loadData(at: "10.png")
        #expect(after == before)
    }

    /// Reading ahead must hand back exactly what a one-at-a-time read does, in
    /// any order, for stored and compressed entries in both RAR formats.
    @Test(arguments: ["panely-rar5.cbr", "panely-rar4.rar"])
    func readAheadPrefixesMatchTheEntries(archive: String) async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive(archive, in: workDir)
        let reader = try RARArchiveReader(url: url)
        let paths = try await reader.entryPaths()
        #expect(paths.count >= 3)

        for maxBytes in [16, 64 * 1024] {
            for path in paths.reversed() {
                let full = try await reader.loadData(at: path)
                let prefix = try await reader.loadDataPrefix(at: path, maxBytes: maxBytes)
                #expect(full.starts(with: prefix), "\(path) at \(maxBytes)")
                #expect(prefix.count >= min(maxBytes, full.count), "\(path) at \(maxBytes)")
            }
        }
        let singleReads = await reader.singlePrefixReadCount
        #expect(singleReads == 0, "compressed entries must be read ahead too")
    }

    /// More entries than one pass holds, and entries past the first pass.
    @Test func readAheadCoversAWholeLargeArchive() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = workDir.appendingPathComponent("big.rar")
        try Self.makeStoredRAR4(entries: 10, payload: 2048, at: url)
        let reader = try RARArchiveReader(url: url, prefixReadAheadCount: 4)
        let paths = try await reader.entryPaths()
        #expect(paths.count == 10)

        for (i, path) in paths.enumerated() {
            let prefix = try await reader.loadDataPrefix(at: path, maxBytes: 1024)
            #expect(prefix.count >= 1024)
            #expect(prefix.first == UInt8(i % 251), "\(path)")
        }
        // The fallback gives the same bytes, so only this shows the passes
        // actually served them instead of degrading to O(n²) again.
        let singleReads = await reader.singlePrefixReadCount
        #expect(singleReads == 0)
    }

    /// A password-protected archive must still report that, not an empty prefix.
    @Test func passwordProtectedArchiveStillReportsThePassword() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar5-password.rar", in: workDir)
        let reader = try RARArchiveReader(url: url)
        let paths = try await reader.entryPaths()
        let path = try #require(paths.first)
        await #expect(throws: ArchiveReaderError.passwordProtected) {
            _ = try await reader.loadDataPrefix(at: path, maxBytes: 64)
        }
    }

    /// Stored-method RAR 4 (no compressor needed), each entry's bytes distinct.
    static func makeStoredRAR4(entries: Int, payload: Int, at url: URL) throws {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
        func crc(_ bytes: [UInt8]) -> UInt32 { UInt32(crc32(0, bytes, UInt32(bytes.count))) }
        func block(_ body: [UInt8]) -> [UInt8] { le16(Int(crc(body) & 0xffff)) + body }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.write(contentsOf: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00] as [UInt8])
        try file.write(contentsOf: block([0x73] + le16(0) + le16(13) + [0, 0, 0, 0, 0, 0]))
        for i in 0..<entries {
            let data = [UInt8](repeating: UInt8(i % 251), count: payload)
            let name = Array(String(format: "pages/%05d.jpg", i).utf8)
            var header: [UInt8] = [0x74] + le16(0x8000) + le16(32 + name.count)
            header += le32(UInt32(payload)) + le32(UInt32(payload)) + [3]
            header += le32(crc(data)) + le32(0x5A21_5C00) + [20, 0x30] + le16(name.count)
            header += le32(0x81A4) + name
            try file.write(contentsOf: block(header))
            try file.write(contentsOf: data)
        }
        try file.write(contentsOf: block([0x7B] + le16(0x4000) + le16(7)))
    }
}

@MainActor
struct OffMainLookupRefreshTests {
    private final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var value = "old"
        private var gate: DispatchSemaphore?
        func set(_ newValue: String) { lock.withLock { value = newValue } }
        func holdNextRead(_ semaphore: DispatchSemaphore) { lock.withLock { gate = semaphore } }
        func read() -> String {
            // Read first, wait after: this lookup has its answer before the change.
            let (current, wait) = lock.withLock { (value, gate) }
            lock.withLock { gate = nil }
            wait?.wait()
            return current
        }
    }

    /// The first lookup of a key read the file, the file then changed and the
    /// library refreshed, all before the answer came back. It must not stick.
    @Test func refreshDuringTheFirstLookupIsNotLost() async {
        let source = Source()
        let release = DispatchSemaphore(value: 0)
        source.holdNextRead(release)
        let lookup = OffMainLookup<String, String> { _ in source.read() }

        #expect(lookup.value(for: "key") == nil)
        // Let the detached read begin before the file changes.
        try? await Task.sleep(for: .milliseconds(50))
        source.set("new")
        lookup.refreshAll()
        release.signal()

        await lookup.settled()
        #expect(lookup.value(for: "key") == "new")
    }
}
