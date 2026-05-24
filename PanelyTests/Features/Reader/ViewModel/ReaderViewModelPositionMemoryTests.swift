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
        withClearedPositions {
            // PositionKey.make returns the standardized path when no temp dir
            // is set, so seeding under that exact path round-trips cleanly.
            let url = URL(fileURLWithPath: "/tmp/seed-test-\(UUID()).cbz")
            let key = url.standardizedFileURL.path

            UserDefaults.standard.set([key: 42] as [String: Int], forKey: ReaderPositionStore.positionsKey)

            let vm = ReaderViewModel()
            // Cache is empty before any access.
            #expect(vm.positions.cache == nil)

            let restored = vm.restoredIndex(for: url)
            #expect(restored == 42)
            // First access hydrates the mirror.
            #expect(vm.positions.cache?[key] == 42)
        }
    }

    @Test func writeRoundTripsThroughCacheAndUserDefaults() {
        withClearedPositions {
            let url = URL(fileURLWithPath: "/tmp/positions-test-\(UUID()).cbz")
            let vm = makePositionViewModel(url: url)

            // Mutating currentPageIndex schedules a debounced save; flush it
            // synchronously to avoid sleeping in the test.
            vm.currentPageIndex = 5
            vm.flushPositionImmediately()

            // A fresh VM should restore the same value via UserDefaults —
            // proves the write actually persisted, not just landed in memory.
            let vm2 = ReaderViewModel()
            vm2.openedSourceURL = url
            #expect(vm2.restoredIndex(for: url) == 5)
        }
    }

    @Test func mirrorReflectsLatestWriteWithoutReReadingDefaults() {
        withClearedPositions {
            let url = URL(fileURLWithPath: "/tmp/mirror-test-\(UUID()).cbz")
            let vm = makePositionViewModel(url: url)

            vm.currentPageIndex = 3
            vm.flushPositionImmediately()
            #expect(vm.restoredIndex(for: url) == 3)

            vm.currentPageIndex = 7
            vm.flushPositionImmediately()
            // Same VM — must read latest from the in-memory mirror.
            #expect(vm.restoredIndex(for: url) == 7)
        }
    }

    @Test func multipleBooksCoexistInTheSameMirror() {
        withClearedPositions {
            let vm = ReaderViewModel()
            let urlA = URL(fileURLWithPath: "/tmp/book-a-\(UUID()).cbz")
            let urlB = URL(fileURLWithPath: "/tmp/book-b-\(UUID()).cbz")
            let pages = makePages()

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

    @Test func zipInZipFileIdentityFallbackDoesNotLeakBetweenInnerVolumes() throws {
        try withClearedPositions {
            let workDir = try Fixture.makeTempDir()
            defer { try? FileManager.default.removeItem(at: workDir) }

            let outerArchive = try writeDummyFile(workDir.appendingPathComponent("Series.cbz"))
            let extractionRoot = workDir.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
            let volumeOne = extractionRoot.appendingPathComponent("Vol01.cbz")
            let volumeTwo = extractionRoot.appendingPathComponent("Vol02.cbz")

            let vm = ReaderViewModel()
            vm.openedSourceURL = outerArchive
            vm.tempDir.url = extractionRoot
            vm.currentSourceURL = volumeOne

            vm.currentPageIndex = 9
            vm.flushPositionImmediately()

            #expect(vm.restoredIndex(for: volumeOne) == 9)
            #expect(vm.restoredIndex(for: volumeTwo) == 0)
        }
    }

    @Test func folderListedZipFileIdentityFallbackDoesNotLeakBetweenVolumes() throws {
        try withClearedPositions {
            let seriesFolder = try Fixture.makeTempDir()
            defer { try? FileManager.default.removeItem(at: seriesFolder) }

            let volumeOne = try writeDummyFile(seriesFolder.appendingPathComponent("Vol01.cbz"))
            let volumeTwo = try writeDummyFile(seriesFolder.appendingPathComponent("Vol02.cbz"))

            let vm = ReaderViewModel()
            vm.openedSourceURL = seriesFolder
            vm.currentSourceURL = volumeOne

            vm.currentPageIndex = 9
            vm.flushPositionImmediately()

            #expect(vm.restoredIndex(for: volumeOne) == 9)
            #expect(vm.restoredIndex(for: volumeTwo) == 0)
        }
    }

    private func withClearedPositions(_ body: () throws -> Void) rethrows {
        UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey) }
        try body()
    }

    private func makePositionViewModel(url: URL, pageCount: Int = 10) -> ReaderViewModel {
        let vm = ReaderViewModel()
        vm.currentSourceURL = url
        vm.source = ComicSource(title: "t", pages: makePages(count: pageCount))
        return vm
    }

    private func makePages(count: Int = 10) -> [ComicPage] {
        (0..<count).map {
            ComicPage(source: .file(URL(fileURLWithPath: "/p\($0).jpg")), displayName: "p\($0)")
        }
    }

    @discardableResult
    private func writeDummyFile(_ url: URL) throws -> URL {
        try Data(url.lastPathComponent.utf8).write(to: url)
        return url
    }
}
