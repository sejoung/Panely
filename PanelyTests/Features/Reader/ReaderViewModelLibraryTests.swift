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
        vm.currentTempDir = nil

        #expect(vm.sidebarVolumes.isEmpty)
    }

    @Test func sidebarVolumesIsEmptyWhenOnlyOneSibling() {
        let vm = ReaderViewModel()
        vm.siblings = [URL(fileURLWithPath: "/var/folders/T/panely-X/Vol01.cbz")]
        vm.currentTempDir = URL(fileURLWithPath: "/var/folders/T/panely-X")

        #expect(vm.sidebarVolumes.isEmpty)
    }

    @Test func sidebarVolumesReturnsSiblingsForZipInZip() {
        let vm = ReaderViewModel()
        let temp = URL(fileURLWithPath: "/var/folders/T/panely-X")
        vm.currentTempDir = temp
        vm.siblings = [
            temp.appendingPathComponent("Vol01.cbz"),
            temp.appendingPathComponent("Vol02.cbz"),
            temp.appendingPathComponent("Vol03.cbz")
        ]

        #expect(vm.sidebarVolumes.count == 3)
        #expect(vm.sidebarVolumes.last?.lastPathComponent == "Vol03.cbz")
    }

    // MARK: - isInsideTempDir

    @Test func isInsideTempDirIsFalseWhenNoTempDir() {
        let vm = ReaderViewModel()
        vm.currentTempDir = nil

        #expect(vm.isInsideTempDir(URL(fileURLWithPath: "/anywhere")) == false)
    }

    @Test func isInsideTempDirMatchesURLsInsideTheTempRoot() {
        let vm = ReaderViewModel()
        let temp = URL(fileURLWithPath: "/var/folders/T/panely-X")
        vm.currentTempDir = temp

        #expect(vm.isInsideTempDir(temp))
        #expect(vm.isInsideTempDir(temp.appendingPathComponent("Vol01.cbz")))
        #expect(vm.isInsideTempDir(temp.appendingPathComponent("nested/file.jpg")))
    }

    @Test func isInsideTempDirRejectsURLsOutsideTheTempRoot() {
        let vm = ReaderViewModel()
        vm.currentTempDir = URL(fileURLWithPath: "/var/folders/T/panely-X")

        #expect(vm.isInsideTempDir(URL(fileURLWithPath: "/var/folders/T/panely-Y/file")) == false)
        #expect(vm.isInsideTempDir(URL(fileURLWithPath: "/Users/me/Comics/book.cbz")) == false)
    }

    @Test func isInsideTempDirRejectsSiblingDirectoryWithSamePrefix() {
        // /a/panely-X must not be considered inside /a/panely — the prefix
        // check has to be path-component aware (uses "/" boundary).
        let vm = ReaderViewModel()
        vm.currentTempDir = URL(fileURLWithPath: "/var/folders/T/panely")

        #expect(vm.isInsideTempDir(URL(fileURLWithPath: "/var/folders/T/panely-X/file")) == false)
    }

    // MARK: - isInsideRootScope

    @Test func isInsideRootScopeIsFalseWhenNoRoot() {
        let vm = ReaderViewModel()
        vm.rootScopedURL = nil

        #expect(vm.isInsideRootScope(URL(fileURLWithPath: "/Users/me/Comics/book.cbz")) == false)
    }

    @Test func isInsideRootScopeMatchesURLsInsideTheRoot() {
        let vm = ReaderViewModel()
        let root = URL(fileURLWithPath: "/Users/me/Comics")
        vm.rootScopedURL = root

        #expect(vm.isInsideRootScope(root))
        #expect(vm.isInsideRootScope(root.appendingPathComponent("series/01")))
    }

    @Test func isInsideRootScopeRejectsURLsOutsideTheRoot() {
        let vm = ReaderViewModel()
        vm.rootScopedURL = URL(fileURLWithPath: "/Users/me/Comics")

        #expect(vm.isInsideRootScope(URL(fileURLWithPath: "/Users/me/Downloads/x.cbz")) == false)
    }

    // MARK: - isInsideCurrentTree

    @Test func isInsideCurrentTreeAcceptsTempOrRootScope() {
        let vm = ReaderViewModel()
        let root = URL(fileURLWithPath: "/Users/me/Comics")
        let temp = URL(fileURLWithPath: "/var/folders/T/panely-X")
        vm.rootScopedURL = root
        vm.currentTempDir = temp

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
