import Testing
import Foundation
@testable import Panely

struct URLRelativeSubpathTests {
    @Test func returnsNilWhenNotUnderRoot() {
        let root = URL(fileURLWithPath: "/a/series")
        #expect(root.relativeSubpath(to: URL(fileURLWithPath: "/a/other/book.cbz")) == nil)
        // Boundary: a sibling that merely shares the prefix string is not under root.
        #expect(root.relativeSubpath(to: URL(fileURLWithPath: "/a/series-extras/book.cbz")) == nil)
    }

    @Test func returnsEmptyStringWhenEqual() {
        let root = URL(fileURLWithPath: "/a/series")
        #expect(root.relativeSubpath(to: URL(fileURLWithPath: "/a/series")) == "")
    }

    @Test func returnsTailWhenUnderRoot() {
        let root = URL(fileURLWithPath: "/tmp/panely-A")
        #expect(root.relativeSubpath(to: URL(fileURLWithPath: "/tmp/panely-A/Vol01.cbz")) == "Vol01.cbz")
        #expect(root.relativeSubpath(to: URL(fileURLWithPath: "/tmp/panely-A/sub/p1.jpg")) == "sub/p1.jpg")
    }

    @Test func isAncestorAgreesWithRelativeSubpath() {
        let root = URL(fileURLWithPath: "/a/series")
        #expect(root.isAncestor(of: URL(fileURLWithPath: "/a/series/v.cbz")))
        #expect(root.isAncestor(of: URL(fileURLWithPath: "/a/series"))) // equal counts as ancestor
        #expect(root.isAncestor(of: URL(fileURLWithPath: "/a/other")) == false)
    }
}
