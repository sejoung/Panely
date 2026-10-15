import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Panely

/// An archive whose entries are counted as they're read, and read slowly —
/// long enough that bands analysed side by side are sure to want the same
/// page while it's still being read.
actor CountingArchiveReader: ArchiveReader {
    nonisolated let archiveURL: URL
    private let entries: [String: Data]
    private let delay: TimeInterval
    private(set) var reads: [String: Int] = [:]

    init(entries: [String: Data], delay: TimeInterval) {
        archiveURL = URL(fileURLWithPath: "/counting/\(UUID().uuidString).cbz")
        self.entries = entries
        self.delay = delay
    }

    func entryPaths() throws -> [String] { entries.keys.sorted() }

    func loadData(at path: String) throws -> Data {
        try Task.checkCancellation()
        reads[path, default: 0] += 1
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        guard let data = entries[path] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }

    func loadDataPrefix(at path: String, maxBytes: Int) throws -> Data {
        guard let data = entries[path] else { throw CocoaError(.fileNoSuchFile) }
        return data.prefix(maxBytes)
    }
}

/// Reads that wait until the test lets them through, logged as they start.
final class BlockingReadLog: @unchecked Sendable {
    private let condition = NSCondition()
    private var paths: [String] = []
    private var released = false

    var started: [String] {
        condition.lock()
        defer { condition.unlock() }
        return paths
    }

    func begin(_ path: String) {
        condition.lock()
        paths.append(path)
        while !released { condition.wait() }
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

actor BlockingArchiveReader: ArchiveReader {
    nonisolated let archiveURL = URL(fileURLWithPath: "/blocking/\(UUID().uuidString).cbz")
    private let entries: [String: Data]
    private let log: BlockingReadLog

    init(entries: [String: Data], log: BlockingReadLog) {
        self.entries = entries
        self.log = log
    }

    func entryPaths() throws -> [String] { entries.keys.sorted() }

    func loadData(at path: String) throws -> Data {
        log.begin(path)
        guard let data = entries[path] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }

    func loadDataPrefix(at path: String, maxBytes: Int) throws -> Data {
        guard let data = entries[path] else { throw CocoaError(.fileNoSuchFile) }
        return data.prefix(maxBytes)
    }
}

/// Strip bands overlap, and in fast mode several are read at once: the
/// analyzer keeps the pages it decoded for the next bands and shares a page
/// still being decoded. Neither may change what's found.
@MainActor
@Suite(.serialized) // OCR is heavy: one band analysis at a time across these tests
struct PageAnalyzerDecodeTests {
    /// Pages of `size` as PNG entries: the drawn manga pages with Japanese
    /// balloons, scaled to fit, or blank ones (quick to run OCR on) when
    /// only the reading counts.
    private func makeBook(count: Int, size: CGSize, delay: TimeInterval, blank: Bool = false) throws -> (CountingArchiveReader, [ComicPage]) {
        var entries: [String: Data] = [:]
        for index in 0..<count {
            let context = try #require(CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            if !blank {
                let drawn = TranslationSnapshotContent.original(TranslationSnapshotContent.pages[index % TranslationSnapshotContent.pages.count])
                context.interpolationQuality = .high
                context.draw(try #require(drawn.cgImage(forProposedRect: nil, context: nil, hints: nil)), in: CGRect(origin: .zero, size: size))
            }
            let cgImage = try #require(context.makeImage())
            entries["\(index).png"] = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        }
        let reader = CountingArchiveReader(entries: entries, delay: delay)
        let pages = (0..<count).map { ComicPage(source: .archiveEntry(reader: reader, path: "\($0).png"), displayName: "\($0).png") }
        return (reader, pages)
    }

    private struct Found: Equatable {
        let pageIndex: Int
        let imageSize: CGSize
        let bubbles: [TranslatedBubble]
    }

    @available(macOS 26.0, *)
    private func analyze(_ analyzer: PageAnalyzer, _ unit: TranslationUnit, _ plan: TranslationPlan) async throws -> [Found] {
        try await analyzer.analyze(unit, plan: plan).map { Found(pageIndex: $0.pageIndex, imageSize: $0.imageSize, bubbles: $0.bubbles) }
    }

    /// Pages in the strip's bands — at least two, sharing pages.
    private func plan(count: Int, size: CGSize) -> TranslationPlan {
        TranslationPlan.strip(StripLayout(pageSizes: Array(repeating: size, count: count)))
    }

    private func drawnPages(_ plan: TranslationPlan, _ unit: Int) -> Set<Int> {
        plan.units[unit].band.map { Set(plan.layout!.pages(intersecting: $0.top..<($0.top + $0.height))) } ?? []
    }

    @Test(.enabled(if: TranslationController.isSupportedOnThisMac), .enabled(if: TestTier.slow, TestTier.slowReason))
    func bandsReadSideBySideDecodeEachPageOnce() async throws {
        guard #available(macOS 26.0, *) else { return }
        let size = TranslationSnapshotContent.pageSize
        let plan = plan(count: 3, size: size)
        try #require(plan.units.count == 2)
        #expect(drawnPages(plan, 0).intersection(drawnPages(plan, 1)) == [1])

        let (reader, pages) = try makeBook(count: 3, size: size, delay: 0.15, blank: true)
        let analyzer = PageAnalyzer(pages: pages, language: .japanese)
        async let first = analyze(analyzer, plan.units[0], plan)
        async let second = analyze(analyzer, plan.units[1], plan)
        _ = try await [first, second]
        #expect(await reader.reads == ["0.png": 1, "1.png": 1, "2.png": 1])
    }

    /// A page kept from the band before draws the next band exactly as a
    /// fresh decode would: the same balloons are found.
    @Test(.enabled(if: TranslationController.isSupportedOnThisMac), .enabled(if: TestTier.slow, TestTier.slowReason))
    func aPageKeptFromTheBandBeforeFindsWhatAFreshOneWould() async throws {
        guard #available(macOS 26.0, *) else { return }
        // Half-size pages: narrow bands are quicker to read.
        let size = CGSize(width: 400, height: 600)
        let plan = plan(count: 5, size: size)
        try #require(plan.units.count == 2)
        let shared = drawnPages(plan, 0).intersection(drawnPages(plan, 1))
        #expect(shared.count >= 1)
        let (reader, pages) = try makeBook(count: 5, size: size, delay: 0)
        let analyzer = PageAnalyzer(pages: pages, language: .japanese)
        _ = try await analyze(analyzer, plan.units[0], plan)
        let kept = try await analyze(analyzer, plan.units[1], plan)
        for page in shared {
            #expect(await reader.reads["\(page).png"] == 1, "page \(page) came from the first band")
        }

        let (_, freshPages) = try makeBook(count: 5, size: size, delay: 0)
        let fresh = try await analyze(PageAnalyzer(pages: freshPages, language: .japanese), plan.units[1], plan)
        #expect(kept == fresh)
        #expect(kept.contains { !$0.bubbles.isEmpty }, "the balloons were read")
    }

    /// Pausing a job cancels its analyses; a band being drawn stops at the
    /// next page instead of reading the rest and running OCR on them.
    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func aCancelledBandReadsNoFurtherPages() async throws {
        guard #available(macOS 26.0, *) else { return }
        let plan = TranslationPlan.strip(StripLayout(pageSizes: Array(repeating: TranslationSnapshotContent.pageSize, count: 3)))
        let (counting, _) = try makeBook(count: 3, size: TranslationSnapshotContent.pageSize, delay: 0, blank: true)
        var entries: [String: Data] = [:]
        for path in ["0.png", "1.png", "2.png"] { entries[path] = try await counting.loadData(at: path) }
        let log = BlockingReadLog()
        let reader = BlockingArchiveReader(entries: entries, log: log)
        let pages = (0..<3).map { ComicPage(source: .archiveEntry(reader: reader, path: "\($0).png"), displayName: "\($0).png") }
        let analyzer = PageAnalyzer(pages: pages, language: .japanese)
        let band = Task { try await analyzer.analyze(plan.units[0], plan: plan) }

        try await waitUntil { log.started == ["0.png"] }
        band.cancel()
        // From here on nothing blocks, so a band that carried on would read on.
        log.releaseAll()
        let result = await band.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(log.started == ["0.png"])
    }

    /// The analysis decodes pages itself now (at utility priority) instead of
    /// through `ImageLoader`. Balloons are placed in its pixels and drawn over
    /// the viewer's, so both must get the very same image — rotated JPEGs and
    /// high-DPI PNGs included, from files and from archives.
    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func theAnalysisDecodesPagesExactlyAsTheViewerDoes() async throws {
        guard #available(macOS 26.0, *) else { return }
        let dir = try Fixture.makeTempDir()
        func encode(_ type: UTType, properties: [CFString: Any]) throws -> Data {
            let context = CGContext(
                data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            for x in 0..<64 {
                context.setFillColor(CGColor(red: CGFloat(x) / 63, green: 0.3, blue: 1 - CGFloat(x) / 63, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 1, height: 20 + x % 20))
            }
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let images: [(String, Data)] = [
            ("rotated.jpg", try encode(.jpeg, properties: [kCGImagePropertyOrientation: 6])),
            ("retina.png", try encode(.png, properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])),
            ("plain.png", try encode(.png, properties: [:])),
        ]
        var pages: [ComicPage] = []
        for (name, data) in images {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            pages.append(ComicPage(source: .file(url), displayName: name))
        }
        let reader = CountingArchiveReader(entries: Dictionary(uniqueKeysWithValues: images), delay: 0)
        pages += images.map { ComicPage(source: .archiveEntry(reader: reader, path: $0.0), displayName: $0.0) }

        for page in pages {
            let analysed = try await PageAnalyzer.decode(page)
            let shown = try #require(try await ImageLoader.load(page).cgImage(forProposedRect: nil, context: nil, hints: nil))
            #expect(analysed.width == shown.width && analysed.height == shown.height, "\(page.displayName) size")
            #expect(analysed.dataProvider?.data as Data? == shown.dataProvider?.data as Data?, "\(page.displayName) pixels")
        }
    }
}
