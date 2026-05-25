import Testing
import Foundation
@testable import Panely

struct ComicPageTests {
    @Test func idIsDeterministicForSameSource() {
        // IDs are derived from the page source so image/thumbnail caches
        // survive a `ComicSource` reload of the same book. Two pages built
        // from the same URL must therefore share an id.
        let url = URL(fileURLWithPath: "/tmp/sample.cbz")
        let a = ComicPage(source: .file(url), displayName: "sample")
        let b = ComicPage(source: .file(url), displayName: "sample")
        #expect(a.id == b.id)
    }

    @Test func idDiffersBetweenSources() {
        let a = ComicPage(source: .file(URL(fileURLWithPath: "/tmp/a.jpg")), displayName: "a")
        let b = ComicPage(source: .file(URL(fileURLWithPath: "/tmp/b.jpg")), displayName: "b")
        #expect(a.id != b.id)
    }

    @Test func idChangesWhenFileContentSignatureChanges() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("page.jpg")
        try Data([1]).write(to: url)
        let first = ComicPage(source: .file(url), displayName: "page")

        try Data([1, 2, 3]).write(to: url)
        let second = ComicPage(source: .file(url), displayName: "page")

        #expect(first.id != second.id)
    }

    @Test func displayNameIsPreserved() {
        let page = ComicPage(
            source: .file(URL(fileURLWithPath: "/tmp/x.cbz")),
            displayName: "Vol 01"
        )
        #expect(page.displayName == "Vol 01")
    }
}

struct ComicSourceTests {
    @Test func emptySourceIsEmpty() {
        let empty = ComicSource.empty
        #expect(empty.isEmpty)
        #expect(empty.pageCount == 0)
        #expect(empty.title.isEmpty)
    }

    @Test func pageCountReflectsPages() {
        let pages = (1...5).map { i in
            ComicPage(
                source: .file(URL(fileURLWithPath: "/p\(i)")),
                displayName: "\(i)"
            )
        }
        let source = ComicSource(title: "Test", pages: pages)
        #expect(source.pageCount == 5)
        #expect(source.isEmpty == false)
        #expect(source.title == "Test")
    }
}
