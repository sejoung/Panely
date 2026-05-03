import AppKit

/// Bridges the macOS Services menu ("Open in Panely") into the SwiftUI scene.
///
/// Registered as `NSApp.servicesProvider` from `PanelyAppDelegate`. When the
/// user picks "Open in Panely" from Finder's right-click → Services submenu,
/// AppKit calls `openInPanely(_:userData:error:)` with the selection on the
/// pasteboard. We forward the first URL via `NotificationCenter` so the
/// SwiftUI WindowGroup can route it through `ReaderViewModel.openURL`.
///
/// Notification (vs. holding a direct viewModel reference) keeps this layer
/// AppKit-only and avoids leaking the @State viewModel out of the App scene.
final class PanelyServiceProvider: NSObject {

    @objc func openInPanely(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let url = urls.first else {
            return
        }

        // Dispatch async so the post happens after the current AppKit run-loop
        // turn — on cold launch the WindowGroup's `.onReceive` subscriber may
        // still be wiring up when this method is first invoked, and a direct
        // synchronous post would be missed.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .panelyOpenURLRequested,
                object: url
            )
        }
    }
}

extension Notification.Name {
    /// Posted by `PanelyServiceProvider` when the user picks "Open in Panely"
    /// from the Services menu. The notification's `object` is the `URL` to open.
    static let panelyOpenURLRequested = Notification.Name("PanelyOpenURLRequested")
}
