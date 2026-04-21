import Testing
import AppKit
@testable import Panely

@MainActor
struct PanelyAppDelegateTests {
    @Test func quitsAfterLastWindowClosed() {
        // Panely is a single-window viewer: closing the main window should
        // terminate the app rather than leave a headless process behind.
        let delegate = PanelyAppDelegate()
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == true)
    }
}
