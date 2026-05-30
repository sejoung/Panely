import Testing
import Foundation
@testable import Panely

@MainActor
struct LastLibraryRootStoreTests {

    private func makeStore(_ defaults: InMemoryKeyValueStore, key: String) -> LastLibraryRootStore {
        LastLibraryRootStore(bookmarks: TestSecurityScopedBookmarkResolver(), defaults: defaults, key: key)
    }

    @Test func saveThenRestoreRoundTrips() {
        let defaults = InMemoryKeyValueStore()
        let key = "root-\(UUID())"
        let store = makeStore(defaults, key: key)
        let dir = URL(fileURLWithPath: "/Users/me/Comics", isDirectory: true)

        store.save(dir)

        #expect(store.restore()?.standardizedFileURL.path == dir.standardizedFileURL.path)
    }

    @Test func restoreSurvivesAcrossStoreInstances() {
        let defaults = InMemoryKeyValueStore()
        let key = "root-\(UUID())"
        let dir = URL(fileURLWithPath: "/Volumes/Library", isDirectory: true)
        makeStore(defaults, key: key).save(dir)

        // A fresh store (next launch) reads the persisted bookmark.
        let reloaded = makeStore(defaults, key: key)
        #expect(reloaded.restore()?.standardizedFileURL.path == dir.standardizedFileURL.path)
    }

    @Test func restoreIsNilWhenNothingSaved() {
        let store = makeStore(InMemoryKeyValueStore(), key: "root-\(UUID())")
        #expect(store.restore() == nil)
    }

    @Test func clearRemovesPersistedRoot() {
        let defaults = InMemoryKeyValueStore()
        let key = "root-\(UUID())"
        let store = makeStore(defaults, key: key)
        store.save(URL(fileURLWithPath: "/x", isDirectory: true))

        store.clear()

        #expect(store.restore() == nil)
    }

    @Test func restoreReturnsNilWhenBookmarkNoLongerResolves() {
        // The folder was deleted / drive ejected since last launch: the saved
        // bookmark can't be resolved anymore. Restore must degrade to "nothing
        // to reopen" rather than surfacing a broken URL.
        let defaults = InMemoryKeyValueStore()
        let key = "root-\(UUID())"
        makeStore(defaults, key: key).save(URL(fileURLWithPath: "/gone", isDirectory: true))

        let store = LastLibraryRootStore(bookmarks: FailingBookmarkResolver(), defaults: defaults, key: key)
        #expect(store.restore() == nil)
    }
}

/// Resolves nothing — models a bookmark whose target no longer exists.
private struct FailingBookmarkResolver: SecurityScopedBookmarking {
    func data(for url: URL) throws -> Data { Data(url.absoluteString.utf8) }
    func resolve(_ bookmarkData: Data) -> SecurityScopedBookmark.Resolution? { nil }
    func refreshedData(for url: URL) -> Data? { nil }
    func isDirectory(_ url: URL) -> Bool { false }
}
