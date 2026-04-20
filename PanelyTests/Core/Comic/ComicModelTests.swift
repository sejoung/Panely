import Testing
import Foundation
@testable import Panely

struct ComicPageTests {
    @Test func createsUniqueIDPerInstance() {
        let url = URL(fileURLWithPath: "/tmp/sample.cbz")
        let a = ComicPage(source: .file(url), displayName: "sample")
        let b = ComicPage(source: .file(url), displayName: "sample")
        #expect(a.id != b.id)
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
