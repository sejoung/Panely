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
