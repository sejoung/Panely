import Testing
import AppKit
import Foundation
@testable import Panely

@MainActor
struct ThumbnailLoaderTests {

    @Test func returnsNilForUnreachableURL() async {
        let page = ComicPage(
            source: .file(URL(fileURLWithPath: "/panely-test-nonexistent/\(UUID().uuidString).png")),
            displayName: "missing.png"
        )
        let result = await ThumbnailLoader.shared.thumbnail(for: page)
        #expect(result == nil)
    }

    @Test func returnsImageForRealPNG() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pngData = try Fixture.makePNG(width: 200, height: 300)
        let url = dir.appendingPathComponent("\(UUID().uuidString).png")
        try pngData.write(to: url)

        let page = ComicPage(source: .file(url), displayName: url.lastPathComponent)

        let result = await ThumbnailLoader.shared.thumbnail(for: page, maxPixelSize: 100)
        guard let thumbnail = result else {
            Issue.record("expected a non-nil thumbnail for a valid PNG")
            return
        }
        // `maxPixelSize` is applied with a 2× retina multiplier, so the
        // thumbnail bounds shouldn't exceed (200, 300) on the longer side.
        #expect(thumbnail.size.width <= 300)
        #expect(thumbnail.size.height <= 300)
    }

    @Test func secondCallForSamePageHitsTheCache() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pngData = try Fixture.makePNG(width: 120, height: 160)
        let url = dir.appendingPathComponent("\(UUID().uuidString).png")
        try pngData.write(to: url)

        // Reuse the same ComicPage so the cache key (page.id) matches.
        let page = ComicPage(source: .file(url), displayName: url.lastPathComponent)

        let first = await ThumbnailLoader.shared.thumbnail(for: page)
        let second = await ThumbnailLoader.shared.thumbnail(for: page)

        guard let first, let second else {
            Issue.record("expected both calls to resolve")
            return
        }
        // Identity equality proves the cache served the second call rather
        // than re-decoding. `NSImage` is a class, so `===` is valid.
        #expect(first === second)
    }

    @Test func differentPagesDoNotCollideInCache() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pngA = try Fixture.makePNG(width: 100, height: 100)
        let pngB = try Fixture.makePNG(width: 100, height: 100)
        let urlA = dir.appendingPathComponent("a-\(UUID().uuidString).png")
        let urlB = dir.appendingPathComponent("b-\(UUID().uuidString).png")
        try pngA.write(to: urlA)
        try pngB.write(to: urlB)

        let pageA = ComicPage(source: .file(urlA), displayName: "a")
        let pageB = ComicPage(source: .file(urlB), displayName: "b")

        let imageA = await ThumbnailLoader.shared.thumbnail(for: pageA)
        let imageB = await ThumbnailLoader.shared.thumbnail(for: pageB)

        guard let imageA, let imageB else {
            Issue.record("expected both thumbnails to resolve")
            return
        }
        // Different `ComicPage.id`s must yield distinct cache entries even
        // when the underlying pixel data is identical.
        #expect(imageA !== imageB)
    }
}
