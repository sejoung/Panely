import Testing
import Foundation
@testable import Panely

/// Focused tests for `ReaderLibraryScope`. The production `acquire(_:)`
/// hits `startAccessingSecurityScopedResource()`, which fails on synthetic
/// file:// URLs that never went through Powerbox — so most tests bypass
/// `acquire` and assign `url` directly to exercise the URL-prefix logic in
/// isolation.
@MainActor
struct ReaderLibraryScopeTests {

    // MARK: - contains() boundary logic

    @Test func containsIsFalseWhenNoURLHeld() {
        let scope = ReaderLibraryScope()
        #expect(scope.contains(URL(fileURLWithPath: "/anywhere")) == false)
    }

    @Test func containsMatchesURLsAtOrBelowRoot() {
        let scope = ReaderLibraryScope()
        let root = URL(fileURLWithPath: "/Users/me/Comics")
        scope.url = root

        #expect(scope.contains(root))
        #expect(scope.contains(root.appendingPathComponent("series")))
        #expect(scope.contains(root.appendingPathComponent("series/01/page.jpg")))
    }

    @Test func containsRejectsURLsOutsideRoot() {
        let scope = ReaderLibraryScope()
        scope.url = URL(fileURLWithPath: "/Users/me/Comics")

        #expect(scope.contains(URL(fileURLWithPath: "/Users/me/Downloads/x.cbz")) == false)
        #expect(scope.contains(URL(fileURLWithPath: "/")) == false)
    }

    @Test func containsRejectsSiblingDirectoryWithSamePrefix() {
        // "/lib/series-extras" must not be considered inside "/lib/series".
        // The prefix check is path-component aware — guards against the
        // classic `hasPrefix(rootPath)` bug.
        let scope = ReaderLibraryScope()
        scope.url = URL(fileURLWithPath: "/lib/series")

        #expect(scope.contains(URL(fileURLWithPath: "/lib/series-extras/book.cbz")) == false)
        #expect(scope.contains(URL(fileURLWithPath: "/lib/series/book.cbz")) == true)
    }

    @Test func containsResolvesStandardizedPaths() {
        // Path with redundant components (./ and //) must still match — the
        // implementation uses `standardizedFileURL` on both sides so callers
        // don't have to pre-normalize.
        let scope = ReaderLibraryScope()
        scope.url = URL(fileURLWithPath: "/lib/comics")

        let messy = URL(fileURLWithPath: "/lib/./comics//book.cbz")
        #expect(scope.contains(messy))
    }

    // MARK: - acquire / release lifecycle

    @Test func releaseClearsHeldURL() {
        let scope = ReaderLibraryScope()
        scope.url = URL(fileURLWithPath: "/lib/comics")
        #expect(scope.isActive)

        scope.release()
        #expect(scope.isActive == false)
        #expect(scope.url == nil)
    }

    @Test func acquireOnUnscopedURLLeavesNoScopeButReleasesAnyPrevious() {
        // A synthetic file:// URL was never granted Powerbox scope, so
        // `startAccessingSecurityScopedResource()` returns false and the
        // scope ends up empty. Crucially the previously held URL is still
        // released — the implementation calls release() first, no matter
        // whether the new acquire succeeds.
        let scope = ReaderLibraryScope()
        scope.url = URL(fileURLWithPath: "/previous")
        #expect(scope.isActive)

        let granted = scope.acquire(URL(fileURLWithPath: "/new/unscoped"))
        #expect(granted == false)
        #expect(scope.isActive == false)
    }

    @Test func releaseIsIdempotent() {
        let scope = ReaderLibraryScope()
        scope.release() // No URL held — must no-op cleanly.
        scope.release()
        #expect(scope.isActive == false)
    }

    // MARK: - isActive flag

    @Test func isActiveReflectsURLPresence() {
        let scope = ReaderLibraryScope()
        #expect(scope.isActive == false)

        scope.url = URL(fileURLWithPath: "/lib")
        #expect(scope.isActive == true)

        scope.url = nil
        #expect(scope.isActive == false)
    }
}
