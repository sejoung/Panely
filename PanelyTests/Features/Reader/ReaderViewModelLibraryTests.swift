import Testing
import Foundation
@testable import Panely

/// Library-root, scope, and temp-dir helpers in ReaderViewModel. These
/// underpin the sidebar's Volumes section visibility (zip-in-zip vs. folder
/// series) and the load() flow's stale-tempDir cleanup branch.
@MainActor
struct ReaderViewModelLibraryTests {

    // MARK: - sidebarVolumes

    @Test func sidebarVolumesIsEmptyForFolderSeriesWithoutTempDir() {
        let vm = ReaderViewModel()
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
        let vm = ReaderViewModel()
        vm.siblings = [URL(fileURLWithPath: "/var/folders/T/panely-X/Vol01.cbz")]
        vm.tempDir.url = URL(fileURLWithPath: "/var/folders/T/panely-X")

        #expect(vm.sidebarVolumes.isEmpty)
    }

    @Test func sidebarVolumesReturnsSiblingsForZipInZip() {
        let vm = ReaderViewModel()
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

    // MARK: - tempDir.contains

    @Test func tempDirContainsIsFalseWhenNoTempDir() {
        let vm = ReaderViewModel()
        vm.tempDir.url = nil

        #expect(vm.tempDir.contains(URL(fileURLWithPath: "/anywhere")) == false)
    }

    @Test func tempDirContainsMatchesURLsInsideTheTempRoot() {
        let vm = ReaderViewModel()
        let temp = URL(fileURLWithPath: "/var/folders/T/panely-X")
        vm.tempDir.url = temp

        #expect(vm.tempDir.contains(temp))
        #expect(vm.tempDir.contains(temp.appendingPathComponent("Vol01.cbz")))
        #expect(vm.tempDir.contains(temp.appendingPathComponent("nested/file.jpg")))
    }

    @Test func tempDirContainsRejectsURLsOutsideTheTempRoot() {
        let vm = ReaderViewModel()
        vm.tempDir.url = URL(fileURLWithPath: "/var/folders/T/panely-X")

        #expect(vm.tempDir.contains(URL(fileURLWithPath: "/var/folders/T/panely-Y/file")) == false)
        #expect(vm.tempDir.contains(URL(fileURLWithPath: "/Users/me/Comics/book.cbz")) == false)
    }

    @Test func tempDirContainsRejectsSiblingDirectoryWithSamePrefix() {
        // /a/panely-X must not be considered inside /a/panely — the prefix
        // check has to be path-component aware (uses "/" boundary).
        let vm = ReaderViewModel()
        vm.tempDir.url = URL(fileURLWithPath: "/var/folders/T/panely")

        #expect(vm.tempDir.contains(URL(fileURLWithPath: "/var/folders/T/panely-X/file")) == false)
    }

    // MARK: - libraryScope.contains

    @Test func libraryScopeContainsIsFalseWhenNoRoot() {
        let vm = ReaderViewModel()
        vm.libraryScope.url = nil

        #expect(vm.libraryScope.contains(URL(fileURLWithPath: "/Users/me/Comics/book.cbz")) == false)
    }

    @Test func libraryScopeContainsMatchesURLsInsideTheRoot() {
        let vm = ReaderViewModel()
        let root = URL(fileURLWithPath: "/Users/me/Comics")
        vm.libraryScope.url = root

        #expect(vm.libraryScope.contains(root))
        #expect(vm.libraryScope.contains(root.appendingPathComponent("series/01")))
    }

    @Test func libraryScopeContainsRejectsURLsOutsideTheRoot() {
        let vm = ReaderViewModel()
        vm.libraryScope.url = URL(fileURLWithPath: "/Users/me/Comics")

        #expect(vm.libraryScope.contains(URL(fileURLWithPath: "/Users/me/Downloads/x.cbz")) == false)
    }

    // MARK: - isInsideCurrentTree

    @Test func isInsideCurrentTreeAcceptsTempOrRootScope() {
        let vm = ReaderViewModel()
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
        let vm = ReaderViewModel()
        vm.explicitLibraryRootURL = URL(fileURLWithPath: "/Users/me/Comics")
        vm.currentSourceURL = URL(fileURLWithPath: "/Users/me/Comics/series/01")

        #expect(vm.libraryRootURL?.path == "/Users/me/Comics")
    }

    @Test func libraryRootURLFallsBackToCurrentSourceParent() {
        let vm = ReaderViewModel()
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
        let vm = ReaderViewModel()
        vm.explicitLibraryRootURL = nil
        vm.openedSourceURL = URL(fileURLWithPath: "/Users/me/Comics/zip-in-zip.cbz")
        vm.currentSourceURL = URL(fileURLWithPath: "/var/folders/T/panely-X/Vol01.cbz")

        #expect(vm.libraryRootURL?.path == "/Users/me/Comics")
    }

    @Test func libraryRootURLIsNilWhenNoSourceAndNoExplicitRoot() {
        let vm = ReaderViewModel()
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

        ReaderTempDirectory.cleanupStaleEntries()

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

        ReaderTempDirectory.cleanupStaleEntries()

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
        let vm = ReaderViewModel()
        let droppedFolder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: droppedFolder) }

        vm.explicitLibraryRootURL = nil
        vm.openedSourceURL = droppedFolder
        vm.currentSourceURL = droppedFolder

        #expect(vm.libraryRootURL?.standardizedFileURL == droppedFolder.standardizedFileURL)
    }

    // MARK: - hasMultipleVolumes

    @Test func hasMultipleVolumesReflectsSiblingCount() {
        let vm = ReaderViewModel()
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
