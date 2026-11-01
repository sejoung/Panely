import Foundation
import Testing
@testable import Panely

/// Work that used to stat, or resolve bookmarks, on the main thread from
/// SwiftUI `body` or a click: it now happens in the background, and the state
/// that matters still gets there.
@MainActor
struct LibraryOffMainWorkTests {

    // MARK: - File identities

    /// The alias is what recovers a remounted book. `body` gets the path key's
    /// answer at once, without a stat, and the alias's as soon as it's known.
    @Test func badgeFindsAnAliasOnlyRecordOnceTheIdentityArrives() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = try Fixture.writeFile(root.appendingPathComponent("Book.cbz"))
        let identity = try #require(PositionKey.fileIdentity(for: book))
        let vm = makeTestViewModel()
        vm.readingProgress.flushImmediately(forKey: identity, fileIdentityKey: nil, page: 9, total: 10, finished: true)
        let revision = vm.readingBadgeIdentityRevision

        #expect(vm.readingBadge(for: book) == nil)

        await vm.badgeIdentities.settled()
        #expect(vm.readingBadge(for: book) == .finished)
        // Observers were told, or nothing would redraw the row.
        #expect(vm.readingBadgeIdentityRevision != revision)
    }

    /// Nearly every row: the identity arrives and changes nothing it shows.
    @Test func anIdentityThatChangesNoBadgeDoesNotInvalidateTheRows() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = try Fixture.writeFile(root.appendingPathComponent("Book.cbz"))
        let vm = makeTestViewModel()
        let revision = vm.readingBadgeIdentityRevision

        #expect(vm.readingBadge(for: book) == nil)
        await vm.badgeIdentities.settled()

        #expect(vm.readingBadge(for: book) == nil)
        #expect(vm.readingBadgeIdentityRevision == revision)
    }

    @Test func aTreeRefreshLooksIdentitiesUpAgain() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = try Fixture.writeFile(root.appendingPathComponent("Book.cbz"))
        let vm = makeTestViewModel()
        _ = vm.readingBadge(for: book)
        await vm.badgeIdentities.settled()

        // Replaced on disk: a new file at the same path has a new identity.
        try FileManager.default.removeItem(at: book)
        _ = try Fixture.writeFile(book)
        let identity = try #require(PositionKey.fileIdentity(for: book))
        vm.readingProgress.flushImmediately(forKey: identity, fileIdentityKey: nil, page: 9, total: 10, finished: true)

        vm.refreshLibraryTree(checkingAvailability: false)
        await vm.badgeIdentities.settled()

        #expect(vm.readingBadge(for: book) == .finished)
    }

    @Test func continueReadingPicksUpAFresherAliasOnceTheIdentityArrives() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = try Fixture.writeFile(root.appendingPathComponent("Book.cbz"))
        let identity = try #require(PositionKey.fileIdentity(for: book))
        let vm = makeTestViewModel()
        vm.recentItems.record(book, title: "Book")
        let progress = vm.readingProgress
        progress.flushImmediately(forKey: book.standardizedFileURL.path, fileIdentityKey: nil, page: 1, total: 10, finished: false)
        progress.flushImmediately(forKey: identity, fileIdentityKey: nil, page: 4, total: 10, finished: false)

        #expect(vm.continueReadingSuggestion?.fraction == 0.2)

        await vm.continueReadingIdentities.settled()
        #expect(vm.continueReadingSuggestion?.fraction == 0.5)
        #expect(vm.continueReadingSuggestion?.fileIdentityKey == identity)
    }

    // MARK: - Recents

    /// The sweep on every app activation mostly confirms what's known. It must
    /// not count as a change: that used to rebuild the Continue Reading index
    /// and re-render the sidebar each time.
    @Test func anAvailabilitySweepThatChangesNothingKeepsTheRevision() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentItemsStore(
            bookmarks: TestSecurityScopedBookmarkResolver(),
            defaults: InMemoryKeyValueStore()
        )
        store.record(try Fixture.writeFile(root.appendingPathComponent("A.cbz")), title: "A")
        _ = await store.refreshAvailability()
        let revision = store.revision

        _ = await store.refreshAvailability()
        #expect(store.revision == revision)

        _ = store.resolve(try #require(store.items.first), allowingMount: false)
        #expect(store.revision == revision)
    }

    @Test func backgroundRecordingKeepsTheOrderBooksWereOpenedIn() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentItemsStore(
            bookmarks: TestSecurityScopedBookmarkResolver(),
            defaults: InMemoryKeyValueStore()
        )
        let a = try Fixture.writeFile(root.appendingPathComponent("A.cbz"))
        let b = try Fixture.writeFile(root.appendingPathComponent("B.cbz"))

        store.recordInBackground(a, title: "A")
        store.recordInBackground(b, title: "B")
        store.recordInBackground(a, title: "A again")
        await store.recordingSettled()

        #expect(store.items.map(\.title) == ["A again", "B"])
        #expect(store.availableURL(for: store.items[0])?.path == a.standardizedFileURL.path)
    }

    // MARK: - Opening favorites

    @Test func openingAFavoriteLoadsIt() async throws {
        let library = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: library) }
        let book = library.appendingPathComponent("Book", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        _ = try Fixture.writeFile(book.appendingPathComponent("001.png"), bytes: Array(Fixture.makePNG(width: 4, height: 4)))
        let vm = makeTestViewModel()
        vm.favorites.toggleFavorite(url: book, title: "Book")

        vm.openFavorite(try #require(vm.favorites.favorites.first))

        // Longer than the default: a real load, and a full parallel run can
        // starve the main actor for that long.
        try await waitUntil(timeout: .seconds(60)) { vm.hasSource && !vm.isLoading }
        await vm.recentItems.recordingSettled()
        #expect(vm.currentSourceURL?.lastPathComponent == "Book")
        #expect(vm.recentItems.items.first?.title == "Book")
    }

    /// Resolving takes a moment now. A book opened meanwhile must win, however
    /// long the favorite's volume took to mount.
    @Test func aFavoriteResolvedAfterALaterOpenGivesWay() async throws {
        let library = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: library) }
        var folders: [URL] = []
        for name in ["Favorite", "Later"] {
            let book = library.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
            _ = try Fixture.writeFile(book.appendingPathComponent("001.png"), bytes: Array(Fixture.makePNG(width: 4, height: 4)))
            folders.append(book)
        }
        let vm = makeTestViewModel()
        vm.favorites.toggleFavorite(url: folders[0], title: "Favorite")

        vm.openFavorite(try #require(vm.favorites.favorites.first))
        await vm.load(url: folders[1])
        try await Task.sleep(for: .milliseconds(200))

        #expect(vm.currentSourceURL?.lastPathComponent == "Later")
    }

    // MARK: - Sibling index

    @Test func currentSiblingIndexFollowsBothInputs() {
        let vm = makeTestViewModel()
        let urls = ["A.cbz", "B", "C.cbz"].map { URL(fileURLWithPath: "/lib/\($0)") }
        #expect(vm.currentSiblingIndex == nil)

        vm.siblings = urls
        #expect(vm.currentSiblingIndex == nil)

        vm.currentSourceURL = urls[2]
        #expect(vm.currentSiblingIndex == 2)

        // A book inside a sibling folder counts as that sibling; a folder that
        // only shares a stem with one doesn't.
        vm.currentSourceURL = URL(fileURLWithPath: "/lib/B/inner/Vol.cbz")
        #expect(vm.currentSiblingIndex == 1)
        vm.currentSourceURL = URL(fileURLWithPath: "/lib/BB/Vol.cbz")
        #expect(vm.currentSiblingIndex == nil)

        vm.currentSourceURL = URL(fileURLWithPath: "/lib/x/../A.cbz")
        #expect(vm.currentSiblingIndex == 0)
        vm.siblings = Array(urls.reversed())
        #expect(vm.currentSiblingIndex == 2)
        vm.currentSourceURL = nil
        #expect(vm.currentSiblingIndex == nil)
    }

    // MARK: - Library root

    @Test func libraryRootFollowsTheOpenedSourcesKind() throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = try Fixture.writeFile(root.appendingPathComponent("Book.cbz"))
        let vm = makeTestViewModel()

        vm.openedSourceURL = folder
        #expect(vm.libraryRootURL == folder)
        vm.openedSourceURL = file
        #expect(vm.libraryRootURL?.standardizedFileURL.path == root.standardizedFileURL.path)
        vm.openedSourceURL = folder
        #expect(vm.libraryRootURL == folder)

        // Missing right now: not remembered as "not a folder".
        let later = root.appendingPathComponent("Later", isDirectory: true)
        vm.openedSourceURL = later
        #expect(vm.libraryRootURL?.standardizedFileURL.path == root.standardizedFileURL.path)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        let fresh = URL(fileURLWithPath: later.path)
        vm.openedSourceURL = fresh
        #expect(vm.libraryRootURL == fresh)
    }
}
