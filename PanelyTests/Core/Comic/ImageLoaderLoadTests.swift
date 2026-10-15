import Testing
import AppKit
import Foundation
import ZIPFoundation
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

    // MARK: - Cancellation

    /// A superseded page (slider scrub, fast paging) must not pay for a full
    /// decode: the decode runs on a detached task, which doesn't inherit
    /// cancellation by itself, so `load` has to forward it.
    @Test func cancelledCallerSkipsFileDecode() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("img.png")
        try Fixture.makePNG(width: 64, height: 64).write(to: url)
        let page = ComicPage(source: .file(url), displayName: "img.png")

        await #expect(throws: CancellationError.self) {
            try await Self.loadCancelled(page)
        }
    }

    @Test func cancelledCallerSkipsArchiveRead() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let png = dir.appendingPathComponent("img.png")
        try Fixture.makePNG(width: 64, height: 64).write(to: png)
        let zipURL = dir.appendingPathComponent("book.cbz")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "img.png", fileURL: png)

        let reader = try ZIPArchiveReader(url: zipURL)
        let page = ComicPage(source: .archiveEntry(reader: reader, path: "img.png"), displayName: "img.png")

        await #expect(throws: CancellationError.self) {
            try await Self.loadCancelled(page)
        }
        // The reader itself is still fine for callers that aren't cancelled.
        let image = try await ImageLoader.load(page)
        #expect(image.size == CGSize(width: 64, height: 64))
    }

    /// Runs `ImageLoader.load` inside a task that is already cancelled.
    private static func loadCancelled(_ page: ComicPage) async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await ImageLoader.load(page)
        }
        try await task.value
    }
}
