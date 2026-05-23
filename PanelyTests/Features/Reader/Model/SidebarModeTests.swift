import Testing
@testable import Panely

struct SidebarModeTests {
    @Test func defaultStateIsUnpinnedAndOverlayHidden() {
        let mode = SidebarMode()
        #expect(mode.pinned == false)
        #expect(mode.overlayVisible == false)
        #expect(mode.visible == false)
    }

    @Test func togglingPinFlipsPinned() {
        var mode = SidebarMode()
        mode.togglePin()
        #expect(mode.pinned == true)
        #expect(mode.visible == true)

        mode.togglePin()
        #expect(mode.pinned == false)
        #expect(mode.visible == false)
    }

    @Test func revealOverlayWorksWhenUnpinned() {
        var mode = SidebarMode()
        mode.revealOverlay()
        #expect(mode.overlayVisible == true)
        #expect(mode.visible == true)
    }

    @Test func revealOverlayIsNoOpWhenPinned() {
        var mode = SidebarMode()
        mode.togglePin() // pinned
        mode.revealOverlay()
        // overlay stays false because pin already covers visibility
        #expect(mode.overlayVisible == false)
    }

    @Test func dismissOverlayHidesIt() {
        var mode = SidebarMode()
        mode.revealOverlay()
        mode.dismissOverlay()
        #expect(mode.overlayVisible == false)
        #expect(mode.visible == false)
    }

    @Test func unpinningDismissesAnyLingeringOverlay() {
        var mode = SidebarMode()
        mode.revealOverlay()      // overlay shown (unpinned)
        mode.togglePin()          // pin → overlay redundant
        mode.togglePin()          // unpin again → must end clean (overlay false)
        #expect(mode.overlayVisible == false)
        #expect(mode.visible == false)
    }

    @Test func visibleIsTrueIfEitherPinnedOrOverlay() {
        var mode = SidebarMode()
        #expect(mode.visible == false)

        mode.revealOverlay()
        #expect(mode.visible == true)

        mode.dismissOverlay()
        mode.togglePin()
        #expect(mode.visible == true)
    }
}
