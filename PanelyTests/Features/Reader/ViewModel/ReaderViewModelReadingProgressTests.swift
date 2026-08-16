import Testing
import Foundation
@testable import Panely

/// Covers `readingBadge(for:)` and `continueReadingSuggestion` — the sidebar's
/// progress-surfacing surface over `ReadingProgressStore` (+ legacy
/// `ReaderPositionStore` fallback).
@MainActor
struct ReaderViewModelReadingProgressTests {

    // MARK: - readingBadge

    @Test func readingBadgeReportsFinished() {
        let vm = makeTestViewModel()
        let url = URL(fileURLWithPath: "/lib/book.cbz")
        vm.readingProgress.flushImmediately(forKey: url.standardizedFileURL.path, fileIdentityKey: nil, page: 40, total: 40, finished: true)

        #expect(vm.readingBadge(for: url) == .finished)
    }

    @Test func readingBadgeReportsInProgressFraction() {
        let vm = makeTestViewModel()
        let url = URL(fileURLWithPath: "/lib/book.cbz")
        vm.readingProgress.flushImmediately(forKey: url.standardizedFileURL.path, fileIdentityKey: nil, page: 4, total: 10, finished: false)

        // fraction = (4 + 1) / 10
        #expect(vm.readingBadge(for: url) == .inProgress(fraction: 0.5))
    }

    @Test func readingBadgeIsNilForUnopenedBook() {
        let vm = makeTestViewModel()
        #expect(vm.readingBadge(for: URL(fileURLWithPath: "/lib/never.cbz")) == nil)
    }

    @Test func readingBadgeFallsBackToLegacyPositionWithoutTotal() {
        let vm = makeTestViewModel()
        let url = URL(fileURLWithPath: "/lib/legacy.cbz")
        // Only a legacy page index exists (no recorded progress / total).
        vm.positions.flushImmediately(forKey: url.standardizedFileURL.path, fileIdentityKey: nil, pageIndex: 3)

        #expect(vm.readingBadge(for: url) == .inProgress(fraction: nil))
    }

    // MARK: - continueReadingSuggestion

    @Test func continueReadingReturnsInProgressBook() {
        let vm = makeTestViewModel()
        let a = URL(fileURLWithPath: "/lib/a.cbz")
        let b = URL(fileURLWithPath: "/lib/b.cbz")
        vm.recentItems.record(a, title: "A")
        vm.recentItems.record(b, title: "B")
        // a finished (excluded), b in progress (the suggestion).
        vm.readingProgress.flushImmediately(forKey: a.standardizedFileURL.path, fileIdentityKey: nil, page: 9, total: 10, finished: true)
        vm.readingProgress.flushImmediately(forKey: b.standardizedFileURL.path, fileIdentityKey: nil, page: 5, total: 10, finished: false)

        let suggestion = vm.continueReadingSuggestion
        #expect(suggestion?.title == "B")
        #expect(suggestion?.fraction == 0.6)
    }

    @Test func continueReadingIsNilWhenOnlyFinishedBooks() {
        let vm = makeTestViewModel()
        let a = URL(fileURLWithPath: "/lib/a.cbz")
        vm.recentItems.record(a, title: "A")
        vm.readingProgress.flushImmediately(forKey: a.standardizedFileURL.path, fileIdentityKey: nil, page: 9, total: 10, finished: true)

        #expect(vm.continueReadingSuggestion == nil)
    }

    @Test func continueReadingIncludesTheCurrentlyReadBook() {
        // The book being read IS the suggestion (it's the most-recently-read,
        // in-progress one) — so opening/selecting a book surfaces it here with
        // live progress rather than hiding it.
        let vm = makeTestViewModel()
        let a = URL(fileURLWithPath: "/lib/a.cbz")
        vm.recentItems.record(a, title: "A")
        vm.readingProgress.flushImmediately(forKey: a.standardizedFileURL.path, fileIdentityKey: nil, page: 2, total: 10, finished: false)
        vm.currentSourceURL = a

        #expect(vm.continueReadingSuggestion?.title == "A")
    }

    @Test func continueReadingTracksMostRecentlyReadVolume() {
        // Flipping to Vol2 (read more recently than Vol1) moves the suggestion
        // to Vol2 — the row follows what you're actually reading.
        let vm = makeTestViewModel()
        let v1 = URL(fileURLWithPath: "/lib/Vol01.cbz")
        let v2 = URL(fileURLWithPath: "/lib/Vol02.cbz")
        vm.recentItems.record(v1, title: "Vol01")
        vm.recentItems.record(v2, title: "Vol02")
        vm.readingProgress.flushImmediately(forKey: v1.standardizedFileURL.path, fileIdentityKey: nil, page: 5, total: 20, finished: false)
        vm.readingProgress.flushImmediately(forKey: v2.standardizedFileURL.path, fileIdentityKey: nil, page: 1, total: 20, finished: false)

        vm.currentSourceURL = v2   // now reading Vol2 (recorded most recently)
        #expect(vm.continueReadingSuggestion?.title == "Vol02")
    }

    @Test func continueReadingFindsZipInZipInnerVolumeProgress() {
        let vm = makeTestViewModel()
        let outer = URL(fileURLWithPath: "/lib/Series.cbz")
        vm.recentItems.record(outer, title: "Series")
        vm.readingProgress.flushImmediately(
            forKey: outer.standardizedFileURL.path + "#Vol02",
            fileIdentityKey: nil,
            page: 6,
            total: 20,
            finished: false
        )

        let suggestion = vm.continueReadingSuggestion
        #expect(suggestion?.title == "Series · Vol02")
        #expect(suggestion?.fraction == 0.35)
        #expect(suggestion?.relativePath == "Vol02")
    }

    @Test func deletedNewestCandidateFallsBackToAvailableBook() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let available = try Fixture.writeFile(root.appendingPathComponent("available.cbz"))
        let deleted = try Fixture.writeFile(root.appendingPathComponent("deleted.cbz"))
        let vm = makeTestViewModel()
        vm.recentItems.record(available, title: "Available")
        vm.readingProgress.flushImmediately(
            forKey: available.standardizedFileURL.path,
            fileIdentityKey: nil,
            page: 2,
            total: 10,
            finished: false
        )
        vm.recentItems.record(deleted, title: "Deleted")
        vm.readingProgress.flushImmediately(
            forKey: deleted.standardizedFileURL.path,
            fileIdentityKey: nil,
            page: 7,
            total: 10,
            finished: false
        )
        try FileManager.default.removeItem(at: deleted)

        await vm.refreshContinueReadingAvailability()

        #expect(vm.continueReadingSuggestion?.title == "Available")
        #expect(vm.recentItems.items.contains { $0.path == deleted.standardizedFileURL.path })
    }

    @Test func temporarilyUnavailableBookReappearsWhenResourceReturns() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = try Fixture.writeFile(root.appendingPathComponent("removable.cbz"))
        let vm = makeTestViewModel()
        vm.recentItems.record(book, title: "Removable")
        vm.readingProgress.flushImmediately(
            forKey: book.standardizedFileURL.path,
            fileIdentityKey: nil,
            page: 3,
            total: 10,
            finished: false
        )
        try FileManager.default.removeItem(at: book)

        await vm.refreshContinueReadingAvailability()
        #expect(vm.continueReadingSuggestion == nil)
        #expect(vm.recentItems.items.count == 1)
        #expect(vm.recentItems.availability(for: vm.recentItems.items[0]) == .temporarilyUnavailable)

        try Fixture.writeFile(book)
        await vm.refreshContinueReadingAvailability()
        #expect(vm.continueReadingSuggestion?.title == "Removable")
    }

    @Test func movedBookmarkMigratesProgressAndRecentPath() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = try Fixture.writeFile(root.appendingPathComponent("old.cbz"))
        let newURL = root.appendingPathComponent("renamed.cbz")
        let resolver = RedirectingBookmarkResolver(destination: newURL)
        let vm = ReaderViewModel(
            dependencies: makeTestDependencies(bookmarkResolver: resolver)
        )
        vm.recentItems.record(oldURL, title: "Moved")
        vm.readingProgress.flushImmediately(
            forKey: oldURL.standardizedFileURL.path,
            fileIdentityKey: nil,
            page: 4,
            total: 10,
            finished: false
        )
        vm.positions.flushImmediately(
            forKey: oldURL.standardizedFileURL.path,
            fileIdentityKey: nil,
            pageIndex: 4
        )
        vm.pageBookmarks.togglePageBookmark(
            key: oldURL.standardizedFileURL.path,
            pageIndex: 6
        )
        try FileManager.default.moveItem(at: oldURL, to: newURL)

        await vm.refreshContinueReadingAvailability()

        #expect(vm.recentItems.items.first?.path == newURL.standardizedFileURL.path)
        #expect(vm.readingProgress.progress(
            forKey: newURL.standardizedFileURL.path,
            fileIdentityKey: nil
        )?.page == 4)
        #expect(vm.readingProgress.progress(
            forKey: oldURL.standardizedFileURL.path,
            fileIdentityKey: nil
        ) == nil)
        #expect(vm.positions.restoredIndex(
            forKey: newURL.standardizedFileURL.path,
            fileIdentityKey: nil
        ) == 4)
        #expect(vm.pageBookmarks.pageBookmarks(
            forKey: newURL.standardizedFileURL.path
        ).map(\.pageIndex) == [6])
        #expect(vm.pageBookmarks.pageBookmarks(
            forKey: oldURL.standardizedFileURL.path
        ).isEmpty)
        #expect(vm.continueReadingSuggestion?.title == "Moved")
    }

    @Test func invalidBookmarkIsHiddenButRetainedForExplicitRemoval() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = try Fixture.writeFile(root.appendingPathComponent("invalid.cbz"))
        let vm = ReaderViewModel(
            dependencies: makeTestDependencies(bookmarkResolver: InvalidBookmarkResolver())
        )
        vm.recentItems.record(book, title: "Invalid")
        vm.readingProgress.flushImmediately(
            forKey: book.standardizedFileURL.path,
            fileIdentityKey: nil,
            page: 3,
            total: 10,
            finished: false
        )

        await vm.refreshContinueReadingAvailability()

        #expect(vm.continueReadingSuggestion == nil)
        #expect(vm.recentItems.items.count == 1)
        #expect(vm.recentItems.availability(for: vm.recentItems.items[0]) == .invalidBookmark)
    }

    @Test func deletedBookClickedFromContinueReadingShowsRemovalAction() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = try Fixture.writeFile(root.appendingPathComponent("deleted.cbz"))
        let vm = makeTestViewModel()
        vm.recentItems.record(book, title: "Deleted")
        vm.readingProgress.flushImmediately(
            forKey: book.standardizedFileURL.path,
            fileIdentityKey: nil,
            page: 3,
            total: 10,
            finished: false
        )
        guard let suggestion = vm.continueReadingSuggestion else {
            Issue.record("expected an available Continue Reading suggestion")
            return
        }
        try FileManager.default.removeItem(at: book)

        vm.openContinueReading(suggestion)
        try await Task.sleep(for: .milliseconds(100))

        #expect(vm.unavailableRecentItem?.id == suggestion.item.id)
        #expect(vm.errorMessage != nil)
        vm.removeUnavailableRecentItem()
        #expect(vm.recentItems.items.isEmpty)
        #expect(vm.readingProgress.entries.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    @Test func containerFolderSurfacesProgressForResolvedChildVolume() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Vol01", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Fixture.writeFile(child.appendingPathComponent("001.jpg"))
        let vm = makeTestViewModel()
        vm.recentItems.record(root, title: "Series")
        vm.readingProgress.flushImmediately(
            forKey: child.standardizedFileURL.path,
            fileIdentityKey: nil,
            page: 4,
            total: 10,
            finished: false
        )

        await vm.refreshContinueReadingAvailability()

        #expect(vm.continueReadingSuggestion?.title == "Series · Vol01")
        #expect(vm.continueReadingSuggestion?.relativePath == "Vol01")

        try FileManager.default.removeItem(at: child)
        await vm.refreshContinueReadingAvailability()
        #expect(vm.continueReadingSuggestion == nil)
    }

    @Test func removeContinueReadingForgetsOnlySelectedProgress() {
        let vm = makeTestViewModel()
        let book = URL(fileURLWithPath: "/lib/book.cbz")
        vm.recentItems.record(book, title: "Book")
        vm.readingProgress.flushImmediately(
            forKey: book.standardizedFileURL.path,
            fileIdentityKey: nil,
            page: 2,
            total: 10,
            finished: false
        )
        let suggestion = vm.continueReadingSuggestion
        #expect(suggestion != nil)

        if let suggestion { vm.removeContinueReading(suggestion) }

        #expect(vm.continueReadingSuggestion == nil)
        #expect(vm.recentItems.items.count == 1)
    }

    @Test func continueSourcesOutliveTenItemOpenRecentMenu() throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let unfinished = try Fixture.writeFile(root.appendingPathComponent("unfinished.cbz"))
        let vm = makeTestViewModel()
        vm.recentItems.record(unfinished, title: "Unfinished")
        vm.readingProgress.flushImmediately(
            forKey: unfinished.standardizedFileURL.path,
            fileIdentityKey: nil,
            page: 2,
            total: 10,
            finished: false
        )
        for index in 0..<10 {
            let other = try Fixture.writeFile(root.appendingPathComponent("other-\(index).cbz"))
            vm.recentItems.record(other, title: "Other \(index)")
        }

        #expect(vm.recentItems.menuItems.count == 10)
        #expect(vm.recentItems.items.count == 11)
        #expect(vm.continueReadingSuggestion?.title == "Unfinished")
    }

    // MARK: - Volume navigation feeds Recents (so Continue Reading tracks it)

    @Test func nextVolumeRecordsTargetInRecents() {
        let vm = makeTestViewModel()
        let v1 = URL(fileURLWithPath: "/lib/Vol01.cbz")
        let v2 = URL(fileURLWithPath: "/lib/Vol02.cbz")
        vm.currentSourceURL = v1
        vm.siblings = [v1, v2]   // on-disk series (tempDir inactive)

        vm.nextVolume()

        // The volume flip records the target in Recents just like a tree click,
        // so the sidebar's Continue Reading no longer goes stale across volumes.
        #expect(vm.recentItems.items.contains { $0.path == v2.standardizedFileURL.path })
    }

    @Test func volumeNavigationSkipsRecentsForZipInZipVolumes() {
        let vm = makeTestViewModel()
        let temp = URL(fileURLWithPath: "/var/folders/T/panely-X")
        vm.tempDir.url = temp
        let v1 = temp.appendingPathComponent("Vol01.cbz")
        let v2 = temp.appendingPathComponent("Vol02.cbz")
        vm.currentSourceURL = v1
        vm.siblings = [v1, v2]

        vm.nextVolume()

        // zip-in-zip volumes live in the temp dir — their bookmark wouldn't
        // resolve next launch, so they're deliberately kept out of Recents.
        #expect(vm.recentItems.items.isEmpty)
    }
}

private nonisolated struct RedirectingBookmarkResolver: SecurityScopedBookmarking {
    let destination: URL

    func data(for url: URL) throws -> Data {
        Data(url.absoluteString.utf8)
    }

    func resolve(_ bookmarkData: Data) -> SecurityScopedBookmark.Resolution? {
        SecurityScopedBookmark.Resolution(url: destination, isStale: false)
    }

    func refreshedData(for url: URL) -> Data? {
        try? data(for: url)
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}

private nonisolated struct InvalidBookmarkResolver: SecurityScopedBookmarking {
    func data(for url: URL) throws -> Data {
        Data(url.absoluteString.utf8)
    }

    func resolve(_ bookmarkData: Data) -> SecurityScopedBookmark.Resolution? {
        nil
    }

    func refreshedData(for url: URL) -> Data? {
        nil
    }

    func isDirectory(_ url: URL) -> Bool {
        false
    }
}
