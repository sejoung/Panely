import Testing
@testable import Panely

@MainActor
struct ReaderViewModelToolbarPinTests {
    @Test func toolbarStartsUnpinnedByDefault() {
        let vm = makeTestViewModel()
        // Default behavior: toolbar auto-hides; pinning is opt-in.
        #expect(vm.toolbarPinned == false)
    }

    @Test func togglingPinFlipsState() {
        let vm = makeTestViewModel()
        vm.toolbarPinned = false // explicit baseline (init may have read true from prior tests)

        vm.toggleToolbarPin()
        #expect(vm.toolbarPinned == true)

        vm.toggleToolbarPin()
        #expect(vm.toolbarPinned == false)
    }
}
