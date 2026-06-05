import Testing
import Foundation
@testable import Panely

/// Per-series direction/layout/fitMode on the view model: the effective value
/// is `series override ?? global default`, changes write through to BOTH, and
/// opening a book restores its series' remembered settings.
@MainActor
@Suite(.serialized)
struct ReaderViewModelSeriesPreferencesTests {

    // MARK: - write-through (series + global)

    @Test func changingDirectionWritesThroughToSeriesAndGlobal() {
        let vm = makeViewModel(at: "/Library/Series A/Vol01.cbz")
        vm.direction = .leftToRight // start known
        let id = vm.seriesIdentity

        vm.direction = .rightToLeft

        #expect(vm.direction == .rightToLeft)                       // effective
        #expect(vm.preferences.direction == .rightToLeft)           // global default
        #expect(vm.seriesPreferences.direction(forSeries: id) == .rightToLeft) // series
    }

    @Test func changingViewModeWritesThroughToSeriesAndGlobal() {
        // View mode == page layout. Its setter has a side effect
        // (handleLayoutChange) but must still write through both ways.
        let vm = makeViewModel(at: "/Library/Webtoon/Vol01.cbz")
        let id = vm.seriesIdentity
        vm.layout = .single // known start

        vm.layout = .vertical

        #expect(vm.preferences.layout == .vertical)
        #expect(vm.seriesPreferences.layout(forSeries: id) == .vertical)
    }

    @Test func applySeriesPreferencesRestoresViewMode() {
        let vm = makeViewModel(at: "/Library/Webtoon B/Vol01.cbz")
        let id = vm.seriesIdentity
        vm.preferences.layout = .single // global default differs
        vm.seriesPreferences.setLayout(.vertical, forSeries: id)

        vm.applySeriesPreferences()

        #expect(vm.layout == .vertical)
    }

    @Test func changingFitModeWritesThroughToSeriesAndGlobal() {
        let vm = makeViewModel(at: "/Library/Series A/Vol01.cbz")
        let id = vm.seriesIdentity

        vm.fitMode = .fitWidth

        #expect(vm.preferences.fitMode == .fitWidth)
        #expect(vm.seriesPreferences.fitMode(forSeries: id) == .fitWidth)
    }

    @Test func changingDirectionWithNoBookOpenWritesGlobalOnly() {
        // No source → empty seriesIdentity → series store stays empty, but the
        // global default still updates (single-file / no-series context).
        let vm = makeTestViewModel()
        #expect(vm.seriesIdentity.isEmpty)

        vm.direction = .rightToLeft

        #expect(vm.preferences.direction == .rightToLeft)
        #expect(vm.seriesPreferences.entries.isEmpty)
    }

    // MARK: - restore on load (applySeriesPreferences)

    @Test func applySeriesPreferencesRestoresRememberedValues() {
        let vm = makeViewModel(at: "/Library/Manga/Vol01.cbz")
        let id = vm.seriesIdentity
        vm.preferences.direction = .leftToRight // global default differs

        // Series was previously read RTL at fit-width.
        vm.seriesPreferences.setDirection(.rightToLeft, forSeries: id)
        vm.seriesPreferences.setFitMode(.fitWidth, forSeries: id)

        vm.applySeriesPreferences()

        #expect(vm.direction == .rightToLeft)
        #expect(vm.fitMode == .fitWidth)
    }

    @Test func unseenSeriesKeepsGlobalDefaultAsStartingPoint() {
        let vm = makeViewModel(at: "/Library/Fresh/Vol01.cbz")
        vm.preferences.direction = .rightToLeft // global default
        // No override stored for this series.

        vm.applySeriesPreferences()

        // Untouched — the global default becomes the series' starting point.
        #expect(vm.direction == .rightToLeft)
        #expect(vm.seriesPreferences.prefs(forSeries: vm.seriesIdentity) == nil)
    }

    @Test func twoSeriesRememberDirectionsIndependently() {
        let defaults = InMemoryKeyValueStore()

        // Read series A as RTL.
        let vmA = makeViewModel(at: "/Library/Manga A/Vol01.cbz", defaults: defaults)
        vmA.direction = .rightToLeft
        let idA = vmA.seriesIdentity

        // Read series B as LTR (same app session, shared store).
        let vmB = makeViewModel(at: "/Library/Comic B/Vol01.cbz", defaults: defaults)
        vmB.direction = .leftToRight
        let idB = vmB.seriesIdentity

        #expect(idA != idB)
        #expect(vmB.seriesPreferences.direction(forSeries: idA) == .rightToLeft)
        #expect(vmB.seriesPreferences.direction(forSeries: idB) == .leftToRight)
    }

    // MARK: - helpers

    private func makeViewModel(
        at path: String,
        defaults: InMemoryKeyValueStore = InMemoryKeyValueStore()
    ) -> ReaderViewModel {
        let vm = makeTestViewModel(keyValueStore: defaults)
        vm.currentSourceURL = URL(fileURLWithPath: path)
        vm.source = ComicSource(title: "t", pages: Fixture.makeImagePages(count: 10))
        return vm
    }
}
