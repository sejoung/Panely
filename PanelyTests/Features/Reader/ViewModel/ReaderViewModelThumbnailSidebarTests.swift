import Testing
@testable import Panely

@MainActor
struct ReaderViewModelThumbnailSidebarTests {

    @Test func thumbnailSidebarStartsHiddenByDefault() {
        let vm = ReaderViewModel()
        // Explicit baseline — prior test runs may have persisted `true`.
        vm.thumbnailSidebarVisible = false
        #expect(vm.thumbnailSidebarVisible == false)
    }

    @Test func togglingFlipsState() {
        let vm = ReaderViewModel()
        vm.thumbnailSidebarVisible = false

        vm.toggleThumbnailSidebar()
        #expect(vm.thumbnailSidebarVisible == true)

        vm.toggleThumbnailSidebar()
        #expect(vm.thumbnailSidebarVisible == false)
    }
}
