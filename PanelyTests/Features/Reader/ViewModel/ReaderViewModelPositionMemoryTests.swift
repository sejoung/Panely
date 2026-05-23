import Testing
import Foundation
@testable import Panely

/// Covers the in-memory positions mirror added on top of UserDefaults. The
/// mirror is meant to keep saves O(1) memcpy + one write instead of an
/// O(N) read-modify-write of the full positions dict every time.
@MainActor
@Suite(.serialized)
struct ReaderViewModelPositionMemoryTests {

    @Test func cachePopulatesFromUserDefaultsOnFirstAccess() {
        // PositionKey.make returns the standardized path when no temp dir
        // is set, so seeding under that exact path round-trips cleanly.
        let url = URL(fileURLWithPath: "/tmp/seed-test-\(UUID()).cbz")
        let key = url.standardizedFileURL.path

        UserDefaults.standard.set([key: 42] as [String: Int], forKey: ReaderPositionStore.positionsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey) }

        let vm = ReaderViewModel()
        // Cache is empty before any access.
        #expect(vm.positions.cache == nil)

        let restored = vm.restoredIndex(for: url)
        #expect(restored == 42)
        // First access hydrates the mirror.
        #expect(vm.positions.cache?[key] == 42)
    }

    @Test func writeRoundTripsThroughCacheAndUserDefaults() {
        UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey) }

        let vm = ReaderViewModel()
        let url = URL(fileURLWithPath: "/tmp/positions-test-\(UUID()).cbz")
        vm.currentSourceURL = url
        vm.source = ComicSource(
            title: "t",
            pages: (0..<10).map {
                ComicPage(source: .file(URL(fileURLWithPath: "/p\($0).jpg")), displayName: "p\($0)")
            }
        )

        // Mutating currentPageIndex schedules a debounced save; flush it
        // synchronously to avoid sleeping in the test.
        vm.currentPageIndex = 5
        vm.flushPositionImmediately()

        // A fresh VM should restore the same value via UserDefaults — proves
        // the write actually persisted, not just landed in our mirror.
        let vm2 = ReaderViewModel()
        vm2.openedSourceURL = url
        #expect(vm2.restoredIndex(for: url) == 5)
    }

    @Test func mirrorReflectsLatestWriteWithoutReReadingDefaults() {
        UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey) }

        let vm = ReaderViewModel()
        let url = URL(fileURLWithPath: "/tmp/mirror-test-\(UUID()).cbz")
        vm.currentSourceURL = url
        vm.source = ComicSource(
            title: "t",
            pages: (0..<10).map {
                ComicPage(source: .file(URL(fileURLWithPath: "/p\($0).jpg")), displayName: "p\($0)")
            }
        )

        vm.currentPageIndex = 3
        vm.flushPositionImmediately()
        #expect(vm.restoredIndex(for: url) == 3)

        vm.currentPageIndex = 7
        vm.flushPositionImmediately()
        // Same VM — must read latest from the in-memory mirror.
        #expect(vm.restoredIndex(for: url) == 7)
    }

    @Test func multipleBooksCoexistInTheSameMirror() {
        UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey) }

        let vm = ReaderViewModel()
        let urlA = URL(fileURLWithPath: "/tmp/book-a-\(UUID()).cbz")
        let urlB = URL(fileURLWithPath: "/tmp/book-b-\(UUID()).cbz")
        let pages = (0..<10).map {
            ComicPage(source: .file(URL(fileURLWithPath: "/p\($0).jpg")), displayName: "p\($0)")
        }

        vm.source = ComicSource(title: "A", pages: pages)
        vm.currentSourceURL = urlA
        vm.currentPageIndex = 4
        vm.flushPositionImmediately()

        vm.source = ComicSource(title: "B", pages: pages)
        vm.currentSourceURL = urlB
        vm.currentPageIndex = 8
        vm.flushPositionImmediately()

        // Both must come back independently — proves we're not overwriting
        // one book's slot when saving another.
        #expect(vm.restoredIndex(for: urlA) == 4)
        #expect(vm.restoredIndex(for: urlB) == 8)
    }
}
