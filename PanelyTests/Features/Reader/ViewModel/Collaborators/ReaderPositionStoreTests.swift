import Testing
import Foundation
@testable import Panely

/// Focused tests for `ReaderPositionStore`, separate from the
/// VM-integration coverage in `ReaderViewModelPositionMemoryTests`. These
/// drive the store directly so any regression isolates to the store rather
/// than mixing in viewmodel state.
@MainActor
struct ReaderPositionStoreTests {

    @Test func restoredIndexReturnsZeroWhenStoreIsEmpty() {
        UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey) }

        let store = ReaderPositionStore()
        #expect(store.restoredIndex(forKey: "anything", fileIdentityKey: nil) == 0)
    }

    @Test func flushImmediatelyWritesThroughToUserDefaults() {
        UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey) }

        let key = "test-\(UUID()).cbz"
        let store = ReaderPositionStore()
        store.flushImmediately(forKey: key, fileIdentityKey: nil, pageIndex: 42)

        // A fresh store hits UserDefaults on first read — proves the write
        // actually persisted, not just landed in the in-memory mirror.
        let reloaded = ReaderPositionStore()
        #expect(reloaded.restoredIndex(forKey: key, fileIdentityKey: nil) == 42)
    }

    @Test func cacheHydratesLazilyOnFirstAccess() {
        UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey) }

        let key = "lazy-\(UUID()).cbz"
        UserDefaults.standard.set([key: 17] as [String: Int], forKey: ReaderPositionStore.positionsKey)

        let store = ReaderPositionStore()
        // Mirror is empty until the first restore/flush touches it.
        #expect(store.cache == nil)
        _ = store.restoredIndex(forKey: key, fileIdentityKey: nil)
        #expect(store.cache?[key] == 17)
    }

    @Test func fileIdentityKeyServesAsFallbackWhenPrimaryMisses() {
        UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey) }

        // Simulates the external-drive remount case: original save was
        // keyed by path "/Volumes/X/book.cbz", but the drive re-mounted as
        // "/Volumes/X 1/book.cbz", so the path key misses on next launch
        // and the file-identity (inode/volume id) key recovers the value.
        let oldPathKey = "/Volumes/X/book.cbz"
        let fidKey = "fid:abc123"
        UserDefaults.standard.set([fidKey: 99] as [String: Int], forKey: ReaderPositionStore.positionsKey)

        let store = ReaderPositionStore()
        let newPathKey = "/Volumes/X 1/book.cbz"
        #expect(store.restoredIndex(forKey: newPathKey, fileIdentityKey: fidKey) == 99)
        // Sanity: with no fid fallback, the new path returns 0.
        #expect(store.restoredIndex(forKey: oldPathKey, fileIdentityKey: nil) == 0)
    }

    @Test func primaryKeyTakesPrecedenceOverFileIdentityKey() {
        UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey) }

        // Both keys present, different values. Primary wins — the user's
        // most recent save under the current path is more trustworthy than
        // the older fid-keyed mirror (which only updates when the primary
        // does, so seeing a stale fid value usually means data drift).
        let pathKey = "main-\(UUID()).cbz"
        let fidKey = "fid-\(UUID())"
        UserDefaults.standard.set(
            [pathKey: 10, fidKey: 99] as [String: Int],
            forKey: ReaderPositionStore.positionsKey
        )

        let store = ReaderPositionStore()
        #expect(store.restoredIndex(forKey: pathKey, fileIdentityKey: fidKey) == 10)
    }

    @Test func flushMirrorsUnderBothPrimaryAndFileIdentityKeys() {
        UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey) }

        let pathKey = "path-\(UUID()).cbz"
        let fidKey = "fid-\(UUID())"
        let store = ReaderPositionStore()
        store.flushImmediately(forKey: pathKey, fileIdentityKey: fidKey, pageIndex: 7)

        // After flush, both keys point at the same page. Either lookup
        // path recovers the saved index.
        let reloaded = ReaderPositionStore()
        #expect(reloaded.restoredIndex(forKey: pathKey, fileIdentityKey: nil) == 7)
        #expect(reloaded.restoredIndex(forKey: "different-path", fileIdentityKey: fidKey) == 7)
    }

    @Test func savePositionDebouncesAndEventuallyPersists() async throws {
        UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey) }

        // The debounced path sleeps ~300 ms before writing. Multiple rapid
        // calls within that window must coalesce into a single write of
        // the last value — that's the whole reason this exists (60 Hz
        // vertical scroll was thrashing UserDefaults).
        let key = "debounce-\(UUID()).cbz"
        let store = ReaderPositionStore()
        store.savePosition(forKey: key, fileIdentityKey: nil, pageIndex: 1)
        store.savePosition(forKey: key, fileIdentityKey: nil, pageIndex: 2)
        store.savePosition(forKey: key, fileIdentityKey: nil, pageIndex: 3)

        // Wait past the debounce window with margin.
        try await Task.sleep(for: .milliseconds(450))

        let reloaded = ReaderPositionStore()
        #expect(reloaded.restoredIndex(forKey: key, fileIdentityKey: nil) == 3)
    }

    @Test func multipleBooksRoundTripIndependently() {
        UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey)
        defer { UserDefaults.standard.removeObject(forKey: ReaderPositionStore.positionsKey) }

        let bookA = "a-\(UUID()).cbz"
        let bookB = "b-\(UUID()).cbz"
        let store = ReaderPositionStore()
        store.flushImmediately(forKey: bookA, fileIdentityKey: nil, pageIndex: 4)
        store.flushImmediately(forKey: bookB, fileIdentityKey: nil, pageIndex: 88)

        // Same store reads back via the in-memory mirror; both entries
        // must coexist — proves writes don't clobber siblings.
        #expect(store.restoredIndex(forKey: bookA, fileIdentityKey: nil) == 4)
        #expect(store.restoredIndex(forKey: bookB, fileIdentityKey: nil) == 88)
    }
}
