import AppKit
import SwiftUI

@main
struct PanelyApp: App {
    @NSApplicationDelegateAdaptor(PanelyAppDelegate.self) private var appDelegate
    @State var viewModel = ReaderViewModel()
    @State var viewerController = ViewerController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .environment(viewerController)
                // Dark-only by design. `PanelyColor` tokens (`bgPrimary` #0F1115
                // etc.) are tuned for a dark reading surface — comic pages have
                // arbitrary content, and a near-black chrome stays out of the
                // way regardless of the page's own palette. A light variant
                // would require duplicating every token and is not on the
                // roadmap; see README.
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    viewModel.openURL(url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            fileCommands
            viewCommands
            goCommands
        }
    }
}

/// Quits the app when the last (and only) window is closed. Panely is a
/// single-window viewer — keeping the process alive with no window visible
/// would leave users wondering why the red close button "only minimizes".
final class PanelyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
