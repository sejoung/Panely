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

    @Test func continueReadingExcludesTheCurrentlyOpenBook() {
        let vm = makeTestViewModel()
        let a = URL(fileURLWithPath: "/lib/a.cbz")
        vm.recentItems.record(a, title: "A")
        vm.readingProgress.flushImmediately(forKey: a.standardizedFileURL.path, fileIdentityKey: nil, page: 2, total: 10, finished: false)
        vm.openedSourceURL = a   // it's the open book — don't suggest "continue" for it

        #expect(vm.continueReadingSuggestion == nil)
    }
}
