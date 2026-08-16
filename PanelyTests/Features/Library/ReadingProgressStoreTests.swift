import Testing
import Foundation
@testable import Panely

@MainActor
@Suite(.serialized)
struct ReadingProgressStoreTests {

    @Test func flushRoundTripsPageTotalAndFinished() {
        let defaults = InMemoryKeyValueStore()
        let key = "rp-\(UUID())"
        let store = ReadingProgressStore(defaults: defaults, storeKey: key)

        store.flushImmediately(forKey: "book", fileIdentityKey: nil, page: 12, total: 40, finished: false)

        // A fresh store hydrates from the injected defaults — proves the write
        // persisted, not just landed in the in-memory mirror.
        let reloaded = ReadingProgressStore(defaults: defaults, storeKey: key)
        let p = reloaded.progress(forKey: "book", fileIdentityKey: nil)
        #expect(p?.page == 12)
        #expect(p?.total == 40)
        #expect(p?.finished == false)
        #expect(p?.fraction == 13.0 / 40.0)
    }

    @Test func finishedFlagPersists() {
        let defaults = InMemoryKeyValueStore()
        let key = "rp-\(UUID())"
        let store = ReadingProgressStore(defaults: defaults, storeKey: key)

        store.flushImmediately(forKey: "done", fileIdentityKey: nil, page: 39, total: 40, finished: true)

        #expect(store.progress(forKey: "done", fileIdentityKey: nil)?.finished == true)
    }

    @Test func fileIdentityKeyServesAsFallback() {
        let store = ReadingProgressStore(defaults: InMemoryKeyValueStore(), storeKey: "rp-\(UUID())")
        store.flushImmediately(forKey: "path", fileIdentityKey: "fid", page: 3, total: 10, finished: false)

        // Path key missed (e.g. external drive remount) → recover via fid.
        #expect(store.progress(forKey: "different-path", fileIdentityKey: "fid")?.page == 3)
    }

    @Test func debouncedRecordEventuallyPersists() async throws {
        let defaults = InMemoryKeyValueStore()
        let key = "rp-\(UUID())"
        let store = ReadingProgressStore(defaults: defaults, storeKey: key)

        store.record(forKey: "b", fileIdentityKey: nil, page: 1, total: 10, finished: false)
        store.record(forKey: "b", fileIdentityKey: nil, page: 2, total: 10, finished: false)
        store.record(forKey: "b", fileIdentityKey: nil, page: 3, total: 10, finished: false)

        try await Task.sleep(for: .milliseconds(450))

        // Rapid calls coalesce into a single write of the last value.
        let reloaded = ReadingProgressStore(defaults: defaults, storeKey: key)
        #expect(reloaded.progress(forKey: "b", fileIdentityKey: nil)?.page == 3)
    }

    @Test func capEvictsLeastRecentlyUpdated() {
        var tick = 0
        let store = ReadingProgressStore(
            defaults: InMemoryKeyValueStore(),
            storeKey: "rp-\(UUID())",
            maxEntries: 3,
            clock: { tick += 1; return Date(timeIntervalSince1970: TimeInterval(tick)) }
        )

        store.flushImmediately(forKey: "a", fileIdentityKey: nil, page: 1, total: 10, finished: false) // t=1
        store.flushImmediately(forKey: "b", fileIdentityKey: nil, page: 1, total: 10, finished: false) // t=2
        store.flushImmediately(forKey: "c", fileIdentityKey: nil, page: 1, total: 10, finished: false) // t=3
        store.flushImmediately(forKey: "a", fileIdentityKey: nil, page: 2, total: 10, finished: false) // t=4 (a now newest)
        store.flushImmediately(forKey: "d", fileIdentityKey: nil, page: 1, total: 10, finished: false) // t=5 → over cap

        #expect(store.entries.count == 3)
        #expect(store.progress(forKey: "b", fileIdentityKey: nil) == nil)   // least-recently-updated evicted
        #expect(store.progress(forKey: "a", fileIdentityKey: nil)?.page == 2) // re-touched, survives
        #expect(store.progress(forKey: "d", fileIdentityKey: nil) != nil)     // newest survives
    }

    @Test func completionStaysFinishedWhenReaderMovesBackward() {
        let store = ReadingProgressStore(
            defaults: InMemoryKeyValueStore(),
            storeKey: "rp-\(UUID())"
        )
        store.flushImmediately(
            forKey: "book",
            fileIdentityKey: nil,
            page: 9,
            total: 10,
            finished: true
        )

        store.flushImmediately(
            forKey: "book",
            fileIdentityKey: nil,
            page: 4,
            total: 10,
            finished: false
        )

        #expect(store.progress(forKey: "book", fileIdentityKey: nil)?.page == 4)
        #expect(store.progress(forKey: "book", fileIdentityKey: nil)?.finished == true)
    }

    @Test func explicitResetStartsFreshReadAfterCompletion() {
        let store = ReadingProgressStore(
            defaults: InMemoryKeyValueStore(),
            storeKey: "rp-\(UUID())"
        )
        store.flushImmediately(
            forKey: "book",
            fileIdentityKey: "fid",
            page: 9,
            total: 10,
            finished: true
        )

        store.resetCompletion(
            forKey: "book",
            fileIdentityKey: "fid",
            page: 0,
            total: 10
        )

        #expect(store.progress(forKey: "book", fileIdentityKey: "fid")?.finished == false)
        #expect(store.progress(forKey: "book", fileIdentityKey: "fid")?.page == 0)
    }

    @Test func pathMigrationMovesDirectNestedAndDirectoryChildEntries() {
        let store = ReadingProgressStore(
            defaults: InMemoryKeyValueStore(),
            storeKey: "rp-\(UUID())"
        )
        store.flushImmediately(forKey: "/old/book.zip", fileIdentityKey: nil, page: 1, total: 10, finished: false)
        store.flushImmediately(forKey: "/old/book.zip#Vol02", fileIdentityKey: nil, page: 2, total: 10, finished: false)
        store.flushImmediately(forKey: "/old/book.zip/child", fileIdentityKey: nil, page: 3, total: 10, finished: false)

        store.migrateSourcePath(from: "/old/book.zip", to: "/new/book.zip")

        #expect(store.progress(forKey: "/old/book.zip", fileIdentityKey: nil) == nil)
        #expect(store.progress(forKey: "/new/book.zip", fileIdentityKey: nil)?.page == 1)
        #expect(store.progress(forKey: "/new/book.zip#Vol02", fileIdentityKey: nil)?.page == 2)
        #expect(store.progress(forKey: "/new/book.zip/child", fileIdentityKey: nil)?.page == 3)
    }
}
