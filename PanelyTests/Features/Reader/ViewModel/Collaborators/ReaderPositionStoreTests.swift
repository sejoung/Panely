import Testing
import Foundation
@testable import Panely

/// Focused tests for `ReaderPositionStore`, separate from the
/// VM-integration coverage in `ReaderViewModelPositionMemoryTests`. These
/// drive the store directly so any regression isolates to the store rather
/// than mixing in viewmodel state.
@MainActor
@Suite(.serialized)
struct ReaderPositionStoreTests {

    @Test func restoredIndexReturnsZeroWhenStoreIsEmpty() {
        let fixture = makeIsolatedStore()
        defer { fixture.cleanup() }

        #expect(fixture.store.restoredIndex(forKey: "anything", fileIdentityKey: nil) == 0)
    }

    @Test func flushImmediatelyWritesThroughToUserDefaults() {
        let fixture = makeIsolatedStore()
        defer { fixture.cleanup() }

        let key = "test-\(UUID()).cbz"
        fixture.store.flushImmediately(forKey: key, fileIdentityKey: nil, pageIndex: 42)

        // A fresh store hits UserDefaults on first read — proves the write
        // actually persisted, not just landed in the in-memory mirror.
        let reloaded = fixture.reloadedStore()
        #expect(reloaded.restoredIndex(forKey: key, fileIdentityKey: nil) == 42)
    }

    @Test func cacheHydratesLazilyOnFirstAccess() {
        let fixture = makeIsolatedStore()
        defer { fixture.cleanup() }

        let key = "lazy-\(UUID()).cbz"
        fixture.defaults.set([key: 17] as [String: Int], forKey: fixture.positionsKey)

        // Mirror is empty until the first restore/flush touches it.
        #expect(fixture.store.cache == nil)
        _ = fixture.store.restoredIndex(forKey: key, fileIdentityKey: nil)
        #expect(fixture.store.cache?[key] == 17)
    }

    @Test func fileIdentityKeyServesAsFallbackWhenPrimaryMisses() {
        let fixture = makeIsolatedStore()
        defer { fixture.cleanup() }

        // Simulates the external-drive remount case: original save was
        // keyed by path "/Volumes/X/book.cbz", but the drive re-mounted as
        // "/Volumes/X 1/book.cbz", so the path key misses on next launch
        // and the file-identity (inode/volume id) key recovers the value.
        let oldPathKey = "/Volumes/X/book.cbz"
        let fidKey = "fid:abc123"
        fixture.defaults.set([fidKey: 99] as [String: Int], forKey: fixture.positionsKey)

        let newPathKey = "/Volumes/X 1/book.cbz"
        #expect(fixture.store.restoredIndex(forKey: newPathKey, fileIdentityKey: fidKey) == 99)
        // Sanity: with no fid fallback, the new path returns 0.
        #expect(fixture.store.restoredIndex(forKey: oldPathKey, fileIdentityKey: nil) == 0)
    }

    @Test func primaryKeyTakesPrecedenceOverFileIdentityKey() {
        let fixture = makeIsolatedStore()
        defer { fixture.cleanup() }

        // Both keys present, different values. Primary wins — the user's
        // most recent save under the current path is more trustworthy than
        // the older fid-keyed mirror (which only updates when the primary
        // does, so seeing a stale fid value usually means data drift).
        let pathKey = "main-\(UUID()).cbz"
        let fidKey = "fid-\(UUID())"
        fixture.defaults.set(
            [pathKey: 10, fidKey: 99] as [String: Int],
            forKey: fixture.positionsKey
        )

        #expect(fixture.store.restoredIndex(forKey: pathKey, fileIdentityKey: fidKey) == 10)
    }

    @Test func flushMirrorsUnderBothPrimaryAndFileIdentityKeys() {
        let fixture = makeIsolatedStore()
        defer { fixture.cleanup() }

        let pathKey = "path-\(UUID()).cbz"
        let fidKey = "fid-\(UUID())"
        fixture.store.flushImmediately(forKey: pathKey, fileIdentityKey: fidKey, pageIndex: 7)

        // After flush, both keys point at the same page. Either lookup
        // path recovers the saved index.
        let reloaded = fixture.reloadedStore()
        #expect(reloaded.restoredIndex(forKey: pathKey, fileIdentityKey: nil) == 7)
        #expect(reloaded.restoredIndex(forKey: "different-path", fileIdentityKey: fidKey) == 7)
    }

    @Test func savePositionDebouncesAndEventuallyPersists() async throws {
        let fixture = makeIsolatedStore()
        defer { fixture.cleanup() }

        // The debounced path sleeps ~300 ms before writing. Multiple rapid
        // calls within that window must coalesce into a single write of
        // the last value — that's the whole reason this exists (60 Hz
        // vertical scroll was thrashing UserDefaults).
        let key = "debounce-\(UUID()).cbz"
        fixture.store.savePosition(forKey: key, fileIdentityKey: nil, pageIndex: 1)
        fixture.store.savePosition(forKey: key, fileIdentityKey: nil, pageIndex: 2)
        fixture.store.savePosition(forKey: key, fileIdentityKey: nil, pageIndex: 3)

        // Wait past the debounce window with margin.
        try await Task.sleep(for: .milliseconds(450))

        let reloaded = fixture.reloadedStore()
        #expect(reloaded.restoredIndex(forKey: key, fileIdentityKey: nil) == 3)
    }

    @Test func multipleBooksRoundTripIndependently() {
        let fixture = makeIsolatedStore()
        defer { fixture.cleanup() }

        let bookA = "a-\(UUID()).cbz"
        let bookB = "b-\(UUID()).cbz"
        fixture.store.flushImmediately(forKey: bookA, fileIdentityKey: nil, pageIndex: 4)
        fixture.store.flushImmediately(forKey: bookB, fileIdentityKey: nil, pageIndex: 88)

        // Same store reads back via the in-memory mirror; both entries
        // must coexist — proves writes don't clobber siblings.
        #expect(fixture.store.restoredIndex(forKey: bookA, fileIdentityKey: nil) == 4)
        #expect(fixture.store.restoredIndex(forKey: bookB, fileIdentityKey: nil) == 88)
    }

    private struct IsolatedStore {
        let store: ReaderPositionStore
        let defaults: UserDefaults
        let suiteName: String
        let positionsKey: String

        @MainActor
        func reloadedStore() -> ReaderPositionStore {
            ReaderPositionStore(defaults: defaults, positionsKey: positionsKey)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeIsolatedStore() -> IsolatedStore {
        let suiteName = "PanelyTests.ReaderPositionStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let positionsKey = "positions-\(UUID().uuidString)"
        return IsolatedStore(
            store: ReaderPositionStore(defaults: defaults, positionsKey: positionsKey),
            defaults: defaults,
            suiteName: suiteName,
            positionsKey: positionsKey
        )
    }
}
