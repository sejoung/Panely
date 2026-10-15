import Testing
import Foundation
@testable import Panely

/// Resolving a security-scoped bookmark may mount its volume (and show UI
/// for a network share). That is right when the user opens the item, and
/// wrong for anything the app does on its own — availability sweeps,
/// launch-time restores, staleness probes, folder-grant lookups — where a
/// silent mount (or a main-thread stall on an unreachable share) isn't what
/// anyone asked for. A recording resolver pins which call sites ask for
/// which (`SecurityScopedBookmark.resolve(_:allowingMount:)` turns `false`
/// into `.withoutUI` + `.withoutMounting`).
@MainActor
@Suite(.serialized)
struct BookmarkResolutionMountPolicyTests {

    @Test func backgroundAvailabilitySweepNeverMounts() async throws {
        let work = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let resolver = RecordingBookmarkResolver()
        let store = RecentItemsStore(bookmarks: resolver, defaults: InMemoryKeyValueStore())
        store.record(try Fixture.writeFile(work.appendingPathComponent("A.cbz")), title: "A")
        store.record(work, title: "Library")
        resolver.reset()

        _ = await store.refreshAvailability()

        #expect(resolver.mountPolicies == [false, false])
    }

    @Test func openingARecentItemMayMount() async throws {
        let work = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let resolver = RecordingBookmarkResolver()
        let store = RecentItemsStore(bookmarks: resolver, defaults: InMemoryKeyValueStore())
        store.record(try Fixture.writeFile(work.appendingPathComponent("A.cbz")), title: "A")
        let item = try #require(store.items.first)
        resolver.reset()

        _ = await store.refreshAvailability(for: item)
        #expect(resolver.mountPolicies == [true])
    }

    @Test func reRecordingAnOpenBookOnlyProbesWithoutMounting() throws {
        let work = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let resolver = RecordingBookmarkResolver()
        let store = RecentItemsStore(bookmarks: resolver, defaults: InMemoryKeyValueStore())
        let book = try Fixture.writeFile(work.appendingPathComponent("A.cbz"))
        store.record(book, title: "A")
        resolver.reset()

        store.record(book, title: "A")
        #expect(resolver.mountPolicies == [false])
    }

    @Test func launchRestoreAndSettingsPeekNeverMount() throws {
        let work = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let resolver = RecordingBookmarkResolver()
        let store = LastLibraryRootStore(bookmarks: resolver, defaults: InMemoryKeyValueStore())
        store.save(work)

        #expect(store.peek() != nil)
        #expect(store.restore() != nil)
        #expect(resolver.mountPolicies == [false, false])
    }

    @Test func openingAFavoriteMayMount() throws {
        let work = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let resolver = RecordingBookmarkResolver()
        let store = FavoritesStore(bookmarks: resolver, defaults: InMemoryKeyValueStore())
        let book = try Fixture.writeFile(work.appendingPathComponent("A.cbz"))
        store.toggleFavorite(url: book, title: "A")
        resolver.reset()

        _ = store.resolve(try #require(store.favorites.first))
        #expect(resolver.mountPolicies == [true])
    }

    @Test func folderGrantLookupNeverMounts() throws {
        let work = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let series = work.appendingPathComponent("Series", isDirectory: true)
        try FileManager.default.createDirectory(at: series, withIntermediateDirectories: true)
        let book = try Fixture.writeFile(series.appendingPathComponent("Vol01.cbz"))
        let resolver = RecordingBookmarkResolver()
        let vm = ReaderViewModel(dependencies: makeTestDependencies(bookmarkResolver: resolver))
        vm.recentItems.record(series, title: "Series")
        vm.lastLibraryRoot.save(work)
        resolver.reset()

        #expect(vm.rememberedFolderGrant(containing: book)?.standardizedFileURL == series.standardizedFileURL)
        #expect(vm.rememberedFolderGrant(containing: work.appendingPathComponent("Loose.cbz"))?.standardizedFileURL
            == work.standardizedFileURL)
        #expect(!resolver.mountPolicies.isEmpty)
        #expect(resolver.mountPolicies.allSatisfy { $0 == false })
    }

    /// Directory-watcher refreshes only rescan the tree; the per-recent
    /// availability sweep (a bookmark resolve + stat each) is for the manual
    /// refresh button.
    @Test func watcherRefreshSkipsTheAvailabilitySweepButManualRefreshRunsIt() async throws {
        let work = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let resolver = RecordingBookmarkResolver()
        let vm = ReaderViewModel(dependencies: makeTestDependencies(bookmarkResolver: resolver))
        vm.recentItems.record(try Fixture.writeFile(work.appendingPathComponent("A.cbz")), title: "A")
        vm.explicitLibraryRootURL = work
        vm.libraryScope.url = work
        vm.syncLibraryWatcher()
        let watcher = try #require(vm.libraryDirectoryWatcher as? TestLibraryDirectoryWatcher)
        resolver.reset()

        let before = vm.libraryRefreshToken
        watcher.triggerChange()
        vm.libraryRefreshDebouncer.flush()
        #expect(vm.libraryRefreshToken != before)
        // Give any spawned sweep ample time to run.
        try await Task.sleep(for: .milliseconds(300))
        #expect(resolver.mountPolicies.isEmpty)

        vm.refreshLibraryTree()
        try await waitUntil { !resolver.mountPolicies.isEmpty }
        #expect(resolver.mountPolicies.allSatisfy { $0 == false })
    }
}

/// Bookmark data is the URL string (like `TestSecurityScopedBookmarkResolver`);
/// every resolve records the mount policy it was asked for.
private final class RecordingBookmarkResolver: SecurityScopedBookmarking, @unchecked Sendable {
    private let lock = NSLock()
    private var policies: [Bool] = []

    var mountPolicies: [Bool] { lock.withLock { policies } }
    func reset() { lock.withLock { policies = [] } }

    func data(for url: URL) throws -> Data {
        Data(url.absoluteString.utf8)
    }

    func resolve(_ bookmarkData: Data) -> SecurityScopedBookmark.Resolution? {
        resolve(bookmarkData, allowingMount: true)
    }

    func resolve(_ bookmarkData: Data, allowingMount: Bool) -> SecurityScopedBookmark.Resolution? {
        lock.withLock { policies.append(allowingMount) }
        guard let raw = String(data: bookmarkData, encoding: .utf8),
              let url = URL(string: raw)
        else { return nil }
        return SecurityScopedBookmark.Resolution(url: url, isStale: false)
    }

    func refreshedData(for url: URL) -> Data? {
        try? data(for: url)
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
