import Testing
import Foundation
@testable import Panely

/// `openSource()` / `requestFolderAccess()` became unit-testable once the
/// `NSOpenPanel` modal was inverted behind the injected `FilePicking` seam —
/// these drive the picker with a fake and assert the resulting VM state.
@MainActor
struct ReaderViewModelOpenSourceTests {

    @Test func openSourceRecordsPickedFileAsRecent() {
        let picked = URL(fileURLWithPath: "/lib/book.cbz")
        let picker = TestFilePicker(urlToReturn: picked)
        let vm = ReaderViewModel(dependencies: makeTestDependencies(filePicker: picker))

        vm.openSource()

        // Open panel allows both files and folders…
        #expect(picker.lastRequest?.canChooseFiles == true)
        #expect(picker.lastRequest?.canChooseDirectories == true)
        // …and the chosen URL is recorded as a recent (the synchronous effect;
        // the async load is fire-and-forget).
        #expect(vm.recentItems.items.first?.path == picked.standardizedFileURL.path)
    }

    @Test func openSourceDoesNothingWhenCancelled() {
        let picker = TestFilePicker(urlToReturn: nil)
        let vm = ReaderViewModel(dependencies: makeTestDependencies(filePicker: picker))

        vm.openSource()

        #expect(picker.lastRequest != nil)      // the panel was presented
        #expect(vm.recentItems.items.isEmpty)    // …but nothing was opened
    }

    @Test func requestFolderAccessSetsLibraryRoot() {
        let folder = URL(fileURLWithPath: "/lib", isDirectory: true)
        let picker = TestFilePicker(urlToReturn: folder)
        let scope = ReaderLibraryScope(
            accessor: TestSecurityScopedResourceAccessor(shouldStart: true)
        )
        let vm = ReaderViewModel(
            dependencies: makeTestDependencies(
                filePicker: picker,
                readerLibraryScopeFactory: { scope }
            )
        )

        vm.requestFolderAccess()

        // Folder-access panel is directories-only…
        #expect(picker.lastRequest?.canChooseFiles == false)
        #expect(picker.lastRequest?.canChooseDirectories == true)
        // …and the picked folder becomes the explicit library root.
        #expect(vm.explicitLibraryRootURL?.standardizedFileURL.path == folder.standardizedFileURL.path)
    }

    @Test func requestFolderAccessDoesNotMutateStateWhenScopeFails() {
        let folder = URL(fileURLWithPath: "/lib", isDirectory: true)
        let picker = TestFilePicker(urlToReturn: folder)
        let scope = ReaderLibraryScope(
            accessor: TestSecurityScopedResourceAccessor(shouldStart: false)
        )
        let vm = ReaderViewModel(
            dependencies: makeTestDependencies(
                filePicker: picker,
                readerLibraryScopeFactory: { scope }
            )
        )

        vm.requestFolderAccess()

        #expect(vm.explicitLibraryRootURL == nil)
        #expect(vm.recentItems.items.isEmpty)
        #expect(vm.errorMessage == "Could not access selected folder.")
    }

    @Test func requestFolderAccessDoesNothingWhenCancelled() {
        let picker = TestFilePicker(urlToReturn: nil)
        let vm = ReaderViewModel(dependencies: makeTestDependencies(filePicker: picker))

        vm.requestFolderAccess()

        #expect(vm.explicitLibraryRootURL == nil)
    }
}
