import Testing
import Foundation
import CoreGraphics
@testable import Panely

struct ImageLoaderDimensionsTests {
    @Test func dimensionsReadsHeaderOfPNGFile() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("img.png")
        try Fixture.makePNG(width: 240, height: 360).write(to: url)

        let page = ComicPage(source: .file(url), displayName: "img.png")
        let size = try await ImageLoader.dimensions(for: page)

        #expect(size == CGSize(width: 240, height: 360))
    }

    @Test func dimensionsThrowsForNonImageFile() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("not-an-image.txt")
        try "hello".data(using: .utf8)!.write(to: url)

        let page = ComicPage(source: .file(url), displayName: "x")
        await #expect(throws: ImageLoaderError.self) {
            try await ImageLoader.dimensions(for: page)
        }
    }
}
