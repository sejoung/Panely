import Foundation
import Testing
@testable import Panely

struct SecurityScopedBookmarkTests {
    @Test func createsAndResolvesBookmarkForFile() throws {
        let resolver = LiveSecurityScopedBookmarkResolver()
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("book.cbz")
        _ = try Fixture.writeFile(file)

        let data = try resolver.data(for: file)
        let resolution = try #require(resolver.resolve(data))

        #expect(
            resolution.url.resolvingSymlinksInPath().path
                == file.resolvingSymlinksInPath().path
        )
    }

    @Test func detectsDirectoryURLs() throws {
        let resolver = LiveSecurityScopedBookmarkResolver()
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(resolver.isDirectory(dir))
    }
}
