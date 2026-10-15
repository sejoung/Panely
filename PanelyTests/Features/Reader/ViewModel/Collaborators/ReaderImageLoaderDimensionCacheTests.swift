import Testing
import AppKit
import Foundation
@testable import Panely

/// The vertical strip's per-book page-dimension cache. It may only answer
/// for exactly the pages it read: a stale size lays the strip out with the
/// wrong slot heights (pages squashed / letterboxed, scroll position off).
///
/// Several tests delete or rewrite the files between refreshes: a fresh
/// header read then fails (→ `fallbackPageSize`) or returns the new size,
/// so the result shows whether the cache answered.
@MainActor
struct ReaderImageLoaderDimensionCacheTests {
    private static let fallback = ReaderImageLoader.fallbackPageSize

    @Test func resetForgetsCachedDimensions() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = try Book(in: root, name: "a", sizes: [CGSize(width: 40, height: 90), CGSize(width: 70, height: 20)])
        let loader = ReaderImageLoader()

        await Self.refreshVertical(loader, book.source)
        #expect(loader.pageDimensions == book.sizes)

        loader.reset()
        try book.deleteFiles()
        await Self.refreshVertical(loader, book.source)

        #expect(loader.pageDimensions == [Self.fallback, Self.fallback])
    }

    /// The cache holds one book: opening another drops the first one's sizes
    /// rather than accumulating every book ever shown.
    @Test func cacheHoldsOnlyTheMostRecentBook() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try Book(in: root, name: "a", sizes: [CGSize(width: 40, height: 90)])
        let second = try Book(in: root, name: "b", sizes: [CGSize(width: 70, height: 20)])
        let loader = ReaderImageLoader()

        await Self.refreshVertical(loader, first.source)
        await Self.refreshVertical(loader, second.source)
        try first.deleteFiles()
        await Self.refreshVertical(loader, first.source)

        #expect(loader.pageDimensions == [Self.fallback])
    }

    /// A page replaced on disk and then reloaded (new `ComicPage`s, whose
    /// ids carry the file's new size + mtime) gets its new size, not the
    /// cached size of the file it replaced at the same path.
    @Test func replacedFileIsNotServedStaleDimensions() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Book(in: root, name: "a", sizes: [CGSize(width: 40, height: 90), CGSize(width: 70, height: 20)])
        let loader = ReaderImageLoader()
        await Self.refreshVertical(loader, original.source)

        let replacedSizes = [CGSize(width: 40, height: 90), CGSize(width: 120, height: 33)]
        try Fixture.makePNG(width: 120, height: 33).write(to: original.urls[1])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: original.urls[1].path
        )
        let reloaded = Book(urls: original.urls, sizes: replacedSizes)
        try #require(reloaded.source.pages[1].id != original.source.pages[1].id)

        await Self.refreshVertical(loader, reloaded.source)

        #expect(loader.pageDimensions == replacedSizes)
    }

    /// A header read that failed (an external drive hiccup, a file still
    /// being written) isn't cached as the fallback size: the next rebuild of
    /// the same pages reads it again.
    @Test func failedHeaderReadIsRetriedOnTheNextRebuild() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = try Book(in: root, name: "a", sizes: [CGSize(width: 40, height: 90), CGSize(width: 70, height: 20)])
        try Data("not an image yet".utf8).write(to: book.urls[1])
        let loader = ReaderImageLoader()

        await Self.refreshVertical(loader, book.source)
        #expect(loader.pageDimensions == [book.sizes[0], Self.fallback])

        // Same `ComicPage`s (same ids): only the bytes on disk changed.
        try Fixture.makePNG(width: 70, height: 20).write(to: book.urls[1])
        await Self.refreshVertical(loader, book.source)

        #expect(loader.pageDimensions == book.sizes)
    }

    // MARK: - Helpers

    private struct Book {
        let urls: [URL]
        let sizes: [CGSize]
        let source: ComicSource

        init(in root: URL, name: String, sizes: [CGSize]) throws {
            let urls = try sizes.enumerated().map { i, size in
                let url = root.appendingPathComponent("\(name)-\(i).png")
                try Fixture.makePNG(width: Int(size.width), height: Int(size.height)).write(to: url)
                return url
            }
            self.init(urls: urls, sizes: sizes)
        }

        init(urls: [URL], sizes: [CGSize]) {
            self.urls = urls
            self.sizes = sizes
            self.source = ComicSource(
                title: "Book",
                pages: urls.map { ComicPage(source: .file($0), displayName: $0.lastPathComponent) }
            )
        }

        func deleteFiles() throws {
            for url in urls { try FileManager.default.removeItem(at: url) }
        }
    }

    private static func refreshVertical(_ loader: ReaderImageLoader, _ source: ComicSource) async {
        await loader.refresh(
            source: source,
            layout: .vertical,
            currentPageIndex: 0,
            navigationStep: 1,
            isCancelled: { false },
            onError: { _ in }
        )
    }
}
