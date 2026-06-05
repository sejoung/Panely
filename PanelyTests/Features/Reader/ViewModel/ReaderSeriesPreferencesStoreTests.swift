import Testing
import Foundation
@testable import Panely

/// `ReaderSeriesPreferencesStore` remembers direction/layout/fitMode per
/// series, persists through an injected key-value store, and caps by recency.
@MainActor
@Suite(.serialized)
struct ReaderSeriesPreferencesStoreTests {

    @Test func setAndReadRoundTripsPerField() {
        let store = makeStore()
        let id = "series:/Library/Manga A"

        store.setDirection(.rightToLeft, forSeries: id)
        store.setFitMode(.fitWidth, forSeries: id)

        #expect(store.direction(forSeries: id) == .rightToLeft)
        #expect(store.fitMode(forSeries: id) == .fitWidth)
        #expect(store.layout(forSeries: id) == nil) // never set → no opinion
    }

    @Test func writePersistsAcrossStoreInstances() {
        let defaults = InMemoryKeyValueStore()
        let id = "series:/Library/Manga B"

        let store = ReaderSeriesPreferencesStore(defaults: defaults)
        store.setLayout(.vertical, forSeries: id)

        // A fresh store reading the same defaults restores the value — proves
        // it persisted, not just landed in the in-memory mirror.
        let reopened = ReaderSeriesPreferencesStore(defaults: defaults)
        #expect(reopened.layout(forSeries: id) == .vertical)
    }

    @Test func seriesAreIsolatedFromEachOther() {
        let store = makeStore()
        store.setDirection(.rightToLeft, forSeries: "series:/A")
        store.setDirection(.leftToRight, forSeries: "series:/B")

        #expect(store.direction(forSeries: "series:/A") == .rightToLeft)
        #expect(store.direction(forSeries: "series:/B") == .leftToRight)
    }

    @Test func emptySeriesIdIsANoOp() {
        let store = makeStore()
        store.setDirection(.rightToLeft, forSeries: "")
        #expect(store.prefs(forSeries: "") == nil)
        #expect(store.entries.isEmpty)
    }

    @Test func unsetSeriesReturnsNil() {
        let store = makeStore()
        #expect(store.direction(forSeries: "series:/never-seen") == nil)
        #expect(store.prefs(forSeries: "series:/never-seen") == nil)
    }

    @Test func recencyCapEvictsOldestSeries() {
        var now = Date(timeIntervalSince1970: 0)
        let store = ReaderSeriesPreferencesStore(
            defaults: InMemoryKeyValueStore(),
            maxEntries: 2,
            clock: { now }
        )

        store.setDirection(.rightToLeft, forSeries: "series:/old")
        now = now.addingTimeInterval(10)
        store.setDirection(.rightToLeft, forSeries: "series:/mid")
        now = now.addingTimeInterval(10)
        store.setDirection(.rightToLeft, forSeries: "series:/new")

        // Cap is 2; the oldest ("old") is evicted, the two recent survive.
        #expect(store.prefs(forSeries: "series:/old") == nil)
        #expect(store.prefs(forSeries: "series:/mid") != nil)
        #expect(store.prefs(forSeries: "series:/new") != nil)
    }

    private func makeStore() -> ReaderSeriesPreferencesStore {
        ReaderSeriesPreferencesStore(defaults: InMemoryKeyValueStore())
    }
}
