import Testing
import Foundation
@testable import Panely

/// Library-root, scope, and temp-dir helpers in ReaderViewModel. These
/// underpin the sidebar's Volumes section visibility (zip-in-zip vs. folder
/// series) and the load() flow's stale-tempDir cleanup branch.
@MainActor
struct ReaderViewModelLibraryTests {

    // MARK: - refreshLibraryTree

    @Test func refreshLibraryTreeChangesRefreshToken() {
        let vm = makeTestViewModel()
        let before = vm.libraryRefreshToken

        vm.refreshLibraryTree()

        // The sidebar's `.task(id:)` keys off this token, so a new value is
        // what forces a re-scan that picks up files added on disk.
        #expect(vm.libraryRefreshToken != before)
    }

    // MARK: - syncLibraryWatcher (auto-refresh)

    @Test func syncLibraryWatcherWatchesScopedLibraryRoot() throws {
        let vm = makeTestViewModel()
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.explicitLibraryRootURL = dir
        vm.libraryScope.url = dir

        vm.syncLibraryWatcher()

        let watcher = vm.libraryDirectoryWatcher as? TestLibraryDirectoryWatcher
        #expect(watcher?.watchedRoot?.standardizedFileURL == dir.standardizedFileURL)
    }

    @Test func directoryChangeRefreshesTreeAfterDebounceQuiet() async throws {
        let vm = makeTestViewModel()
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.explicitLibraryRootURL = dir
        vm.libraryScope.url = dir
        vm.syncLibraryWatcher()

        let before = vm.libraryRefreshToken
        (vm.libraryDirectoryWatcher as? TestLibraryDirectoryWatcher)?.triggerChange()

        // Debounced: a single event does NOT refresh immediately (that's what
        // prevents a busy/cloud root from storming re-scans).
        #expect(vm.libraryRefreshToken == before)

        // After the folder stays quiet past the debounce window, it refreshes once.
        try await Task.sleep(for: .milliseconds(1700))
        #expect(vm.libraryRefreshToken != before)
    }

    @Test func autoRefreshDisabledStartsNoWatcherButStillPersistsRoot() throws {
        // Production config: FSEvents auto-refresh off. No watcher is started
        // (so it can't storm re-scans), but the last-library-root is still
        // persisted for next-launch restore, and the manual refresh button
        // remains functional.
        let vm = ReaderViewModel(dependencies: makeTestDependencies(libraryAutoRefreshEnabled: false))
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.explicitLibraryRootURL = dir
        vm.libraryScope.url = dir

        vm.syncLibraryWatcher()

        #expect(vm.libraryDirectoryWatcher == nil)
        #expect(vm.lastLibraryRoot.restore()?.standardizedFileURL.path == dir.standardizedFileURL.path)
    }

    @Test func syncLibraryWatcherSkipsRootWithoutScopeAccess() throws {
        let vm = makeTestViewModel()
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Root set but no security scope acquired → can't read it → don't watch
        // (mirrors single-file opens whose derived root is an unreadable parent).
        vm.explicitLibraryRootURL = dir

        vm.syncLibraryWatcher()

        #expect(vm.libraryDirectoryWatcher == nil)
    }

    @Test func syncLibraryWatcherSkipsRedundantRestartForSameRoot() throws {
        let vm = makeTestViewModel()
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.explicitLibraryRootURL = dir
        vm.libraryScope.url = dir
        vm.syncLibraryWatcher()
        let watcher = vm.libraryDirectoryWatcher as? TestLibraryDirectoryWatcher

        vm.syncLibraryWatcher()  // same root → no teardown/restart

        #expect(watcher?.stopCount == 0)
        #expect(watcher?.watchedRoot?.standardizedFileURL == dir.standardizedFileURL)
    }

    // MARK: - Last library root (auto-restore)

    @Test func establishingLibraryRootPersistsItForNextLaunch() throws {
        let vm = makeTestViewModel()
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.explicitLibraryRootURL = dir
        vm.libraryScope.url = dir

        vm.syncLibraryWatcher()

        // Settling on a scoped library directory records it for restore.
        #expect(vm.lastLibraryRoot.restore()?.standardizedFileURL.path == dir.standardizedFileURL.path)
    }

    @Test func restoreSkipsWhenABookIsAlreadyOpen() {
        let vm = makeTestViewModel()
        vm.lastLibraryRoot.save(URL(fileURLWithPath: "/lib", isDirectory: true))
        // Launched with a file (or already loaded one): don't override it.
        vm.currentSourceURL = URL(fileURLWithPath: "/lib/book.cbz")

        vm.restoreLastLibraryRootIfNeeded()

        #expect(vm.explicitLibraryRootURL == nil)
    }

    @Test func restoreDoesNothingWhenNothingPersisted() {
        let vm = makeTestViewModel()

        vm.restoreLastLibraryRootIfNeeded()

        #expect(vm.explicitLibraryRootURL == nil)
        #expect(vm.libraryDirectoryWatcher == nil)
    }

    @Test func restoreBailsWhenLibraryScopeCannotBeAcquired() {
        // The persisted folder is gone, so even though a URL is produced the
        // security-scope grant fails. Restore must leave the app with no root
        // (and no watcher) rather than half-applying a dead library.
        let vm = makeTestViewModel()
        vm.lastLibraryRoot.save(URL(fileURLWithPath: "/nonexistent-\(UUID())", isDirectory: true))

        vm.restoreLastLibraryRootIfNeeded()

        #expect(vm.explicitLibraryRootURL == nil)
        #expect(vm.libraryDirectoryWatcher == nil)
    }

    @Test func reopenLastFolderOnLaunchDefaultsTrueAndPersists() {
        let store = InMemoryKeyValueStore()
        let vm = ReaderViewModel(dependencies: makeTestDependencies(keyValueStore: store))
        #expect(vm.reopenLastFolderOnLaunch == true)

        vm.reopenLastFolderOnLaunch = false

        // A fresh viewmodel over the same store reads the persisted choice.
        let reloaded = ReaderViewModel(dependencies: makeTestDependencies(keyValueStore: store))
        #expect(reloaded.reopenLastFolderOnLaunch == false)
    }

    @Test func restoreSkippedWhenReopenOnLaunchDisabled() {
        let vm = makeTestViewModel()
        vm.lastLibraryRoot.save(URL(fileURLWithPath: "/lib", isDirectory: true))
        vm.reopenLastFolderOnLaunch = false

        vm.restoreLastLibraryRootIfNeeded()

        #expect(vm.explicitLibraryRootURL == nil)
        #expect(vm.libraryDirectoryWatcher == nil)
    }

    @Test func forgetLastLibraryRootClearsSavedFolder() {
        let vm = makeTestViewModel()
        let dir = URL(fileURLWithPath: "/lib", isDirectory: true)
        vm.lastLibraryRoot.save(dir)
        #expect(vm.hasRememberedLibraryRoot)
        #expect(vm.rememberedLibraryRoot?.standardizedFileURL.path == dir.standardizedFileURL.path)

        vm.forgetLastLibraryRoot()

        #expect(!vm.hasRememberedLibraryRoot)
        #expect(vm.rememberedLibraryRoot == nil)
        #expect(vm.lastLibraryRoot.restore() == nil)
    }

    @Test func stopLibraryWatcherTearsDownAndClears() throws {
        let vm = makeTestViewModel()
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.explicitLibraryRootURL = dir
        vm.libraryScope.url = dir
        vm.syncLibraryWatcher()
        let watcher = vm.libraryDirectoryWatcher as? TestLibraryDirectoryWatcher

        vm.stopLibraryWatcher()

        #expect(watcher?.stopCount == 1)
        #expect(vm.libraryDirectoryWatcher == nil)
        #expect(vm.watchedLibraryRootURL == nil)
    }

    // MARK: - sidebarVolumes

    @Test func sidebarVolumesIsEmptyForFolderSeriesWithoutTempDir() {
        let vm = makeTestViewModel()
        // Folder series: siblings live in the user's library tree, so a
        // separate Volumes section would just duplicate the Files tree.
        vm.siblings = [
            URL(fileURLWithPath: "/lib/series/01"),
            URL(fileURLWithPath: "/lib/series/02"),
            URL(fileURLWithPath: "/lib/series/03")
        ]
        vm.tempDir.url = nil

        #expect(vm.sidebarVolumes.isEmpty)
    }

    @Test func sidebarVolumesIsEmptyWhenOnlyOneSibling() {
        let vm = makeTestViewModel()
        vm.siblings = [URL(fileURLWithPath: "/var/folders/T/panely-X/Vol01.cbz")]
        vm.tempDir.url = URL(fileURLWithPath: "/var/folders/T/panely-X")

        #expect(vm.sidebarVolumes.isEmpty)
    }

    @Test func sidebarVolumesReturnsSiblingsForZipInZip() {
        let vm = makeTestViewModel()
        let temp = URL(fileURLWithPath: "/var/folders/T/panely-X")
        vm.tempDir.url = temp
        vm.siblings = [
            temp.appendingPathComponent("Vol01.cbz"),
            temp.appendingPathComponent("Vol02.cbz"),
            temp.appendingPathComponent("Vol03.cbz")
        ]

        #expect(vm.sidebarVolumes.count == 3)
        #expect(vm.sidebarVolumes.last?.lastPathComponent == "Vol03.cbz")
    }

    @Test func sidebarActiveURLPrefersPendingSourceWhileLoading() {
        let vm = makeTestViewModel()
        let current = URL(fileURLWithPath: "/library/Vol01.cbz")
        let pending = URL(fileURLWithPath: "/library/Vol02.cbz")
        vm.currentSourceURL = current
        vm.pendingSourceURL = pending

        #expect(vm.sidebarActiveURL?.standardizedFileURL == pending.standardizedFileURL)
    }

    @Test func successfulLoadClearsPendingSourceURL() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("001.png")
        try Fixture.makePNG(width: 10, height: 10).write(to: imageURL)

        let vm = makeTestViewModel()
        let initialSourceRevision = vm.sourceRenderRevision
        await vm.load(url: root)

        #expect(vm.currentSourceURL?.standardizedFileURL == root.standardizedFileURL)
        #expect(vm.pendingSourceURL == nil)
        #expect(vm.sidebarActiveURL?.standardizedFileURL == root.standardizedFileURL)
        #expect(vm.sourceRenderRevision == initialSourceRevision + 1)
    }

    @Test func successfulLoadStartsSourceChangeMonitor() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPage = root.appendingPathComponent("001.png")
        let secondPage = root.appendingPathComponent("002.png")
        try Fixture.makePNG(width: 10, height: 10).write(to: firstPage)
        try Fixture.makePNG(width: 10, height: 10).write(to: secondPage)

        let monitor = TestSourceChangeMonitor()
        let vm = ReaderViewModel(
            dependencies: makeTestDependencies(sourceChangeMonitorFactory: { monitor })
        )

        await vm.load(url: root)

        #expect(monitor.watchedURL?.standardizedFileURL == root.standardizedFileURL)
        #expect(Set(monitor.watchedURLs.map(\.standardizedFileURL)) == Set([
            root.standardizedFileURL,
            firstPage.standardizedFileURL,
            secondPage.standardizedFileURL,
        ]))
    }

    @Test func largeFolderLoadCapsSourceChangeMonitorURLs() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<(ReaderViewModel.maxPageFileWatchCount + 1) {
            let page = root.appendingPathComponent(String(format: "%03d.png", index))
            try Fixture.makePNG(width: 10, height: 10).write(to: page)
        }

        let monitor = TestSourceChangeMonitor()
        let vm = ReaderViewModel(
            dependencies: makeTestDependencies(sourceChangeMonitorFactory: { monitor })
        )

        await vm.load(url: root)

        #expect(monitor.watchedURL?.standardizedFileURL == root.standardizedFileURL)
        #expect(monitor.watchedURLs.map(\.standardizedFileURL) == [root.standardizedFileURL])
    }

    @Test func sourceChangeMonitorMarksAndNextLoadClearsNotice() async throws {
        let first = try Fixture.makeTempDir()
        let second = try Fixture.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try Fixture.makePNG(width: 10, height: 10)
            .write(to: first.appendingPathComponent("001.png"))
        try Fixture.makePNG(width: 10, height: 10)
            .write(to: second.appendingPathComponent("001.png"))

        let monitor = TestSourceChangeMonitor()
        let vm = ReaderViewModel(
            dependencies: makeTestDependencies(sourceChangeMonitorFactory: { monitor })
        )

        await vm.load(url: first)
        monitor.triggerChange()

        #expect(vm.sourceChangedOnDisk)
        #expect(vm.sourceChangeMessage != nil)

        await vm.load(url: second)

        #expect(vm.sourceChangedOnDisk == false)
        #expect(vm.sourceChangeMessage == nil)
        #expect(monitor.watchedURL?.standardizedFileURL == second.standardizedFileURL)
    }

    @Test func loadingContainerFolderDescendsToNestedZipSeries() async throws {
        let root = try Fixture.makeTempDir()
        let series = root.appendingPathComponent("Manga Series", isDirectory: true)
        let vol01Pages = root.appendingPathComponent("vol01-pages", isDirectory: true)
        let vol02Pages = root.appendingPathComponent("vol02-pages", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: series, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vol01Pages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vol02Pages, withIntermediateDirectories: true)
        try Fixture.makePNG(width: 10, height: 10)
            .write(to: vol01Pages.appendingPathComponent("001.png"))
        try Fixture.makePNG(width: 12, height: 10)
            .write(to: vol02Pages.appendingPathComponent("001.png"))

        let vol01 = series.appendingPathComponent("01.zip")
        let vol02 = series.appendingPathComponent("02.zip")
        try Fixture.zipDirectory(vol01Pages, to: vol01)
        try Fixture.zipDirectory(vol02Pages, to: vol02)

        let vm = makeTestViewModel()
        await vm.load(url: root)

        #expect(vm.errorMessage == nil)
        #expect(vm.currentSourceURL?.standardizedFileURL == vol01.standardizedFileURL)
        #expect(vm.source.pageCount == 1)
        #expect(vm.siblings.map(\.standardizedFileURL) == [
            vol01.standardizedFileURL,
            vol02.standardizedFileURL,
        ])
    }
    // MARK: - tempDir.contains

    @Test func tempDirContainsIsFalseWhenNoTempDir() {
        let vm = makeTestViewModel()
        vm.tempDir.url = nil

        #expect(vm.tempDir.contains(URL(fileURLWithPath: "/anywhere")) == false)
    }

    @Test func tempDirContainsMatchesURLsInsideTheTempRoot() {
        let vm = makeTestViewModel()
        let temp = URL(fileURLWithPath: "/var/folders/T/panely-X")
        vm.tempDir.url = temp

        #expect(vm.tempDir.contains(temp))
        #expect(vm.tempDir.contains(temp.appendingPathComponent("Vol01.cbz")))
        #expect(vm.tempDir.contains(temp.appendingPathComponent("nested/file.jpg")))
    }

    @Test func tempDirContainsRejectsURLsOutsideTheTempRoot() {
        let vm = makeTestViewModel()
        vm.tempDir.url = URL(fileURLWithPath: "/var/folders/T/panely-X")

        #expect(vm.tempDir.contains(URL(fileURLWithPath: "/var/folders/T/panely-Y/file")) == false)
        #expect(vm.tempDir.contains(URL(fileURLWithPath: "/Users/me/Comics/book.cbz")) == false)
    }

    @Test func tempDirContainsRejectsSiblingDirectoryWithSamePrefix() {
        // /a/panely-X must not be considered inside /a/panely — the prefix
        // check has to be path-component aware (uses "/" boundary).
        let vm = makeTestViewModel()
        vm.tempDir.url = URL(fileURLWithPath: "/var/folders/T/panely")

        #expect(vm.tempDir.contains(URL(fileURLWithPath: "/var/folders/T/panely-X/file")) == false)
    }

    // MARK: - libraryScope.contains

    @Test func libraryScopeContainsIsFalseWhenNoRoot() {
        let vm = makeTestViewModel()
        vm.libraryScope.url = nil

        #expect(vm.libraryScope.contains(URL(fileURLWithPath: "/Users/me/Comics/book.cbz")) == false)
    }

    @Test func libraryScopeContainsMatchesURLsInsideTheRoot() {
        let vm = makeTestViewModel()
        let root = URL(fileURLWithPath: "/Users/me/Comics")
        vm.libraryScope.url = root

        #expect(vm.libraryScope.contains(root))
        #expect(vm.libraryScope.contains(root.appendingPathComponent("series/01")))
    }

    @Test func libraryScopeContainsRejectsURLsOutsideTheRoot() {
        let vm = makeTestViewModel()
        vm.libraryScope.url = URL(fileURLWithPath: "/Users/me/Comics")

        #expect(vm.libraryScope.contains(URL(fileURLWithPath: "/Users/me/Downloads/x.cbz")) == false)
    }

    // MARK: - isInsideCurrentTree

    @Test func isInsideCurrentTreeAcceptsTempOrRootScope() {
        let vm = makeTestViewModel()
        let root = URL(fileURLWithPath: "/Users/me/Comics")
        let temp = URL(fileURLWithPath: "/var/folders/T/panely-X")
        vm.libraryScope.url = root
        vm.tempDir.url = temp

        #expect(vm.isInsideCurrentTree(root.appendingPathComponent("a.cbz")))
        #expect(vm.isInsideCurrentTree(temp.appendingPathComponent("Vol01.cbz")))
        #expect(vm.isInsideCurrentTree(URL(fileURLWithPath: "/elsewhere/b.cbz")) == false)
    }

    // MARK: - libraryRootURL

    @Test func libraryRootURLPrefersExplicitOverCurrentSourceParent() {
        let vm = makeTestViewModel()
        vm.explicitLibraryRootURL = URL(fileURLWithPath: "/Users/me/Comics")
        vm.currentSourceURL = URL(fileURLWithPath: "/Users/me/Comics/series/01")

        #expect(vm.libraryRootURL?.path == "/Users/me/Comics")
    }

    @Test func libraryRootURLFallsBackToCurrentSourceParent() {
        let vm = makeTestViewModel()
        vm.explicitLibraryRootURL = nil
        vm.openedSourceURL = nil
        vm.currentSourceURL = URL(fileURLWithPath: "/Users/me/Comics/series/01")

        #expect(vm.libraryRootURL?.path == "/Users/me/Comics/series")
    }

    @Test func libraryRootURLPrefersOpenedSourceParentOverCurrentSource() {
        // zip-in-zip cold start: currentSourceURL points inside the extracted
        // temp dir, but the user opened the outer archive from their library.
        // The library tree must reflect the user's actual location, not the
        // temp folder (whose contents are surfaced via the Volumes section).
        let vm = makeTestViewModel()
        vm.explicitLibraryRootURL = nil
        vm.openedSourceURL = URL(fileURLWithPath: "/Users/me/Comics/zip-in-zip.cbz")
        vm.currentSourceURL = URL(fileURLWithPath: "/var/folders/T/panely-X/Vol01.cbz")

        #expect(vm.libraryRootURL?.path == "/Users/me/Comics")
    }

    @Test func libraryRootURLIsNilWhenNoSourceAndNoExplicitRoot() {
        let vm = makeTestViewModel()
        vm.explicitLibraryRootURL = nil
        vm.openedSourceURL = nil
        vm.currentSourceURL = nil

        #expect(vm.libraryRootURL == nil)
    }

    // MARK: - ReaderTempDirectory.cleanupStaleEntries

    @Test func cleanupStaleTempDirsRemovesPanelyPrefixedAndSparesOthers() throws {
        // Mimics the on-launch sweep: a previous crash leaves a `panely-*`
        // dir behind, while unrelated tmp entries (other apps, the user's
        // own files) must survive. The prefix + mtime check is the contract.
        let tmpRoot = FileManager.default.temporaryDirectory
        let stale = tmpRoot.appendingPathComponent(
            "panely-stale-\(UUID().uuidString)",
            isDirectory: true
        )
        let unrelated = tmpRoot.appendingPathComponent(
            "notpanely-keep-\(UUID().uuidString)",
            isDirectory: true
        )

        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        // Backdate the stale dir past the sweep threshold (10 min). Without
        // this, freshly-created `panely-*` dirs are left alone — that's by
        // design so concurrent first-launch extractions aren't deleted.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: stale.path
        )
        defer {
            try? FileManager.default.removeItem(at: stale)
            try? FileManager.default.removeItem(at: unrelated)
        }

        ReaderTempDirectory.cleanupStaleEntries(extractionCache: TestExtractionCacheManager())

        #expect(!FileManager.default.fileExists(atPath: stale.path),
                "Stale panely-* dir must be removed")
        #expect(FileManager.default.fileExists(atPath: unrelated.path),
                "Non-panely tmp entries must be left alone")
    }

    @Test func cleanupStaleTempDirsSparesFreshlyCreatedPanelyDirs() throws {
        // A first-launch extraction races the cleanup task. A freshly-made
        // `panely-*` dir must survive the sweep so the in-flight load isn't
        // deleted out from under itself.
        let tmpRoot = FileManager.default.temporaryDirectory
        let fresh = tmpRoot.appendingPathComponent(
            "panely-fresh-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fresh) }

        ReaderTempDirectory.cleanupStaleEntries(extractionCache: TestExtractionCacheManager())

        #expect(FileManager.default.fileExists(atPath: fresh.path),
                "Freshly created panely-* dir must survive the sweep")
    }

    @Test func fixtureTempDirNamespaceDoesNotCollideWithCleanupSweep() throws {
        // Regression guard for the race that hit CI: if `Fixture.makeTempDir`
        // ever produces a name matching the `panely-*` sweep above, parallel
        // tests lose their fixture files mid-await. Either side widening its
        // namespace must trip this.
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(
            !dir.lastPathComponent.hasPrefix("panely-"),
            "Fixture dir \(dir.lastPathComponent) collides with ReaderTempDirectory.cleanupStaleEntries()'s panely-* prefix"
        )
    }

    @Test func libraryRootURLUsesOpenedFolderItselfWhenDirectory() throws {
        // Drag-drop / Open With on a folder: Powerbox grants the sandbox
        // scope on exactly that URL. Climbing to the parent would silently
        // hit a permission wall (FileManager returns []) and the sidebar
        // would render the misleading "No books to show" prompt. The opened
        // folder itself must be the library root.
        let vm = makeTestViewModel()
        let droppedFolder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: droppedFolder) }

        vm.explicitLibraryRootURL = nil
        vm.openedSourceURL = droppedFolder
        vm.currentSourceURL = droppedFolder

        #expect(vm.libraryRootURL?.standardizedFileURL == droppedFolder.standardizedFileURL)
    }

    @Test func sidebarFolderSelectionAfterZipInZipPreservesLibraryRoot() async throws {
        let library = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: library) }

        let selectedFolder = library.appendingPathComponent("Other Series", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: true)
        try Fixture.makePNG(width: 10, height: 10)
            .write(to: selectedFolder.appendingPathComponent("001.png"))

        let temp = try Fixture.makeTempDir()
        let innerVolume = temp.appendingPathComponent("Vol01.cbz")

        let vm = makeTestViewModel()
        vm.openedSourceURL = library.appendingPathComponent("zip-in-zip.cbz")
        vm.currentSourceURL = innerVolume
        vm.tempDir.url = temp

        await vm.load(url: selectedFolder, intent: .librarySelection)

        #expect(vm.tempDir.isActive == false)
        #expect(vm.explicitLibraryRootURL?.standardizedFileURL == library.standardizedFileURL)
        #expect(vm.libraryRootURL?.standardizedFileURL == library.standardizedFileURL)
        #expect(vm.openedSourceURL?.standardizedFileURL == selectedFolder.standardizedFileURL)
        #expect(vm.currentSourceURL?.standardizedFileURL == selectedFolder.standardizedFileURL)
    }

    @Test func nestedArchiveExtractionFailureStopsLoadAndPreservesError() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let outerSrc = try Fixture.makeTempDir()
        try Data("not a zip".utf8).write(to: outerSrc.appendingPathComponent("Vol01.cbz"))
        let outerZip = workDir.appendingPathComponent("broken-series.cbz")
        try Fixture.zipDirectory(outerSrc, to: outerZip)
        try? FileManager.default.removeItem(at: outerSrc)

        let vm = makeTestViewModel()
        await vm.load(url: outerZip)

        #expect(vm.source.isEmpty)
        #expect(vm.currentSourceURL == nil)
        #expect(vm.currentImages.isEmpty)
        #expect(vm.errorMessage?.hasPrefix("Failed to extract archive:") == true)
    }

    @Test func failedLoadInsideLibraryPreservesLibraryScopeAndWatcher() async throws {
        let library = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: library) }

        let brokenBook = library.appendingPathComponent("Broken.cbz")
        try Data("not a zip".utf8).write(to: brokenBook)

        let watcher = TestLibraryDirectoryWatcher()
        let scope = ReaderLibraryScope(
            accessor: TestSecurityScopedResourceAccessor(shouldStart: true)
        )
        let vm = ReaderViewModel(
            dependencies: makeTestDependencies(
                libraryDirectoryWatcherFactory: { watcher },
                readerLibraryScopeFactory: { scope }
            )
        )
        vm.explicitLibraryRootURL = library
        #expect(vm.libraryScope.acquire(library))
        vm.syncLibraryWatcher()

        await vm.load(url: brokenBook)

        #expect(vm.source.isEmpty)
        #expect(vm.currentSourceURL == nil)
        #expect(vm.errorMessage != nil)
        #expect(vm.libraryScope.url?.standardizedFileURL == library.standardizedFileURL)
        #expect(vm.libraryRootURL?.standardizedFileURL == library.standardizedFileURL)
        #expect(watcher.watchedRoot?.standardizedFileURL == library.standardizedFileURL)
    }

    @Test func preferredInnerPathCannotEscapeExtractionRoot() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let innerSrc = try Fixture.makeTempDir()
        try Fixture.makePNG(width: 10, height: 10)
            .write(to: innerSrc.appendingPathComponent("page.png"))
        let innerZip = workDir.appendingPathComponent("Vol01.cbz")
        try Fixture.zipDirectory(innerSrc, to: innerZip)
        try? FileManager.default.removeItem(at: innerSrc)

        let outerSrc = try Fixture.makeTempDir()
        try FileManager.default.moveItem(at: innerZip, to: outerSrc.appendingPathComponent("Vol01.cbz"))
        let outerZip = workDir.appendingPathComponent("series.cbz")
        try Fixture.zipDirectory(outerSrc, to: outerZip)
        try? FileManager.default.removeItem(at: outerSrc)

        let cache = TestExtractionCacheManager()
        guard let cacheKey = cache.cacheKey(for: outerZip) else {
            Issue.record("expected cache key for fixture archive")
            return
        }
        let extractionRoot = cache.makeCachedCandidate(forKey: cacheKey)
        let outside = extractionRoot
            .deletingLastPathComponent()
            .appendingPathComponent("outside", isDirectory: true)
        try? FileManager.default.removeItem(at: extractionRoot)
        try? FileManager.default.removeItem(at: outside)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Fixture.makePNG(width: 10, height: 10)
            .write(to: outside.appendingPathComponent("outside.png"))
        defer {
            try? FileManager.default.removeItem(at: extractionRoot)
            try? FileManager.default.removeItem(at: outside)
        }

        let vm = makeTestViewModel(extractionCache: cache)
        await vm.load(url: outerZip, intent: .favorite(innerPath: "../outside"))

        #expect(
            vm.currentSourceURL?.standardizedFileURL
                == extractionRoot.appendingPathComponent("Vol01", isDirectory: true).standardizedFileURL
        )
    }

    // MARK: - hasMultipleVolumes

    @Test func hasMultipleVolumesReflectsSiblingCount() {
        let vm = makeTestViewModel()
        #expect(vm.hasMultipleVolumes == false)

        vm.siblings = [URL(fileURLWithPath: "/a")]
        #expect(vm.hasMultipleVolumes == false)

        vm.siblings = [
            URL(fileURLWithPath: "/a"),
            URL(fileURLWithPath: "/b")
        ]
        #expect(vm.hasMultipleVolumes)
    }
}
