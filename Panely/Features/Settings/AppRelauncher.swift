import AppKit

/// Quits Panely and opens it again — how a language change takes effect,
/// since macOS only picks an app's localization at launch.
@MainActor
enum AppRelauncher {
    /// Launches a fresh instance, then terminates this one. The new instance
    /// is started first so a failure leaves the user with a running app and
    /// an explanation rather than no app at all.
    ///
    /// `reopening` hands the open book to the new instance the same way
    /// Finder would, so a language switch mid-read lands back on the book
    /// (at its saved page) instead of an empty window.
    static func relaunch(reopening bookURL: URL? = nil) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let completion: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, error in
            Task { @MainActor in
                if let error {
                    AppLog.error(
                        .app,
                        "Relaunch failed",
                        metadata: ["error": "\(error.localizedDescription)"]
                    )
                    presentFailure()
                    return
                }
                AppLog.info(.app, "Relaunching to apply settings")
                NSApp.terminate(nil)
            }
        }
        if let bookURL {
            NSWorkspace.shared.open(
                [bookURL],
                withApplicationAt: Bundle.main.bundleURL,
                configuration: configuration,
                completionHandler: completion
            )
        } else {
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: configuration,
                completionHandler: completion
            )
        }
    }

    private static func presentFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could not restart Panely.", bundle: .localized)
        alert.informativeText = String(localized: "Quit and reopen Panely to apply the new language.", bundle: .localized)
        alert.addButton(withTitle: String(localized: "OK", bundle: .localized))
        alert.runModal()
    }
}
