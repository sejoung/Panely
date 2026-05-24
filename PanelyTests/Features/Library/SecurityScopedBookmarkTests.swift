import Foundation
import Testing
@testable import Panely

struct SecurityScopedBookmarkTests {
    @Test func createsAndResolvesBookmarkForFile() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("book.cbz")
        _ = try Fixture.writeFile(file)

        let data = try SecurityScopedBookmark.data(for: file)
        let resolution = try #require(SecurityScopedBookmark.resolve(data))

        #expect(
            resolution.url.resolvingSymlinksInPath().path
                == file.resolvingSymlinksInPath().path
        )
    }

    @Test func detectsDirectoryURLs() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(SecurityScopedBookmark.isDirectory(dir))
    }
}
