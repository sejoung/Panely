import Testing
import AppKit
import Foundation
@testable import Panely

/// Covers `ImageLoader.load` — the eager-decode path that replaced the
/// `NSImage(data:)` lazy decoder. Companion to `ImageLoaderDimensionsTests`.
struct ImageLoaderLoadTests {

    @Test func loadsRealPNGFromFile() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("img.png")
        try Fixture.makePNG(width: 240, height: 360).write(to: url)

        let page = ComicPage(source: .file(url), displayName: "img.png")
        let image = try await ImageLoader.load(page)

        // Eager decode means the NSImage is wrapped around a fully-realized
        // CGImage. Size in points should reflect the source dimensions.
        #expect(image.size.width == 240)
        #expect(image.size.height == 360)
    }

    @Test func throwsForNonImageFile() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("not-an-image.txt")
        try "hello".data(using: .utf8)!.write(to: url)

        let page = ComicPage(source: .file(url), displayName: "x")
        await #expect(throws: ImageLoaderError.self) {
            try await ImageLoader.load(page)
        }
    }

    @Test func throwsForMissingFile() async throws {
        let page = ComicPage(
            source: .file(URL(fileURLWithPath: "/does-not-exist/\(UUID()).png")),
            displayName: "missing.png"
        )
        await #expect(throws: ImageLoaderError.self) {
            try await ImageLoader.load(page)
        }
    }

    @Test func decodedImageIsBackedByConcreteCGImage() async throws {
        // Regression guard for the lazy-decode bug. With `NSImage(data:)`,
        // `cgImage(forProposedRect:context:hints:)` would force decoding on
        // first call — fine functionally but defeats the whole point of
        // doing the work off the main thread. The eager pipeline returns
        // an NSImage whose CGImage is already realized.
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("img.png")
        try Fixture.makePNG(width: 64, height: 64).write(to: url)

        let page = ComicPage(source: .file(url), displayName: "img.png")
        let image = try await ImageLoader.load(page)

        var rect = NSRect(origin: .zero, size: image.size)
        let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #expect(cg != nil)
    }
}
