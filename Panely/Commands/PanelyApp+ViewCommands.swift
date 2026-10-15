import SwiftUI

extension PanelyApp {
    /// The View menu: chrome toggles → layout → fit → zoom → auto-fit
    /// lock, separated by dividers in that order so keyboard shortcuts
    /// cluster by intent (`⌃⌘X` chrome, `⇧⌘1-3` layout, `⌘1-3` fit,
    /// `⌘+/-/0` zoom).
    ///
    /// Added to the system's View menu (ahead of Enter Full Screen) rather
    /// than declared as a `CommandMenu("View")`, which puts a second,
    /// identically named menu in the menu bar.
    @CommandsBuilder
    var viewCommands: some Commands {
        CommandGroup(before: .toolbar) {
            Button(
                viewModel.sidebarPinned
                    ? String(localized: "Unpin Library", bundle: .localized)
                    : String(localized: "Pin Library", bundle: .localized)
            ) {
                viewModel.toggleSidebarPin()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])

            Button(
                viewModel.toolbarPinned
                    ? String(localized: "Unpin Toolbar", bundle: .localized)
                    : String(localized: "Pin Toolbar", bundle: .localized)
            ) {
                viewModel.toggleToolbarPin()
            }
            .keyboardShortcut("t", modifiers: [.control, .command])

            Button(
                viewModel.thumbnailSidebarVisible
                    ? String(localized: "Hide Thumbnails", bundle: .localized)
                    : String(localized: "Show Thumbnails", bundle: .localized)
            ) {
                viewModel.toggleThumbnailSidebar()
            }
            .keyboardShortcut("p", modifiers: [.control, .command])
            .disabled(!viewModel.hasSource)

            Divider()

            Button(String(localized: "Single Page", bundle: .localized)) {
                viewModel.setLayout(.single)
            }
            .keyboardShortcut("1", modifiers: [.command, .shift])
            .disabled(viewModel.layout == .single)

            Button(String(localized: "Double Page", bundle: .localized)) {
                viewModel.setLayout(.double)
            }
            .keyboardShortcut("2", modifiers: [.command, .shift])
            .disabled(viewModel.layout == .double)

            Button(String(localized: "Vertical Scroll", bundle: .localized)) {
                viewModel.setLayout(.vertical)
            }
            .keyboardShortcut("3", modifiers: [.command, .shift])
            .disabled(viewModel.layout == .vertical)

            Divider()

            Button(String(localized: "Fit to Screen", bundle: .localized)) {
                viewModel.setFitMode(.fitScreen)
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(viewModel.fitMode == .fitScreen)

            Button(String(localized: "Fit to Width", bundle: .localized)) {
                viewModel.setFitMode(.fitWidth)
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(viewModel.fitMode == .fitWidth)

            Button(String(localized: "Fit to Height", bundle: .localized)) {
                viewModel.setFitMode(.fitHeight)
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(viewModel.fitMode == .fitHeight)

            Divider()

            Button(String(localized: "Zoom In", bundle: .localized)) {
                viewerController.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)

            Button(String(localized: "Zoom Out", bundle: .localized)) {
                viewerController.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)

            Button(String(localized: "Reset Zoom", bundle: .localized)) {
                viewerController.resetZoom()
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()

            Button(
                viewModel.autoFitOnResize
                    ? String(localized: "Lock View Size", bundle: .localized)
                    : String(localized: "Unlock View Size", bundle: .localized)
            ) {
                viewModel.toggleAutoFitOnResize()
            }
            .keyboardShortcut("l", modifiers: .command)

            Button(
                viewModel.wheelPageTurn
                    ? String(localized: "Disable Scroll Page Turning", bundle: .localized)
                    : String(localized: "Enable Scroll Page Turning", bundle: .localized)
            ) {
                viewModel.toggleWheelPageTurn()
            }

            Divider()

            if viewModel.translationFeatureAvailable {
                Button(
                    viewModel.translationOverlayVisible
                        ? String(localized: "Hide Translation", bundle: .localized)
                        : String(localized: "Show Translation", bundle: .localized)
                ) {
                    viewModel.toggleTranslationOverlay()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!viewModel.hasSource)

                Button(
                    viewModel.translation.isWorking
                        ? String(localized: "Pause Translating", bundle: .localized)
                        : String(localized: "Translate This Book", bundle: .localized)
                ) {
                    viewModel.toggleTranslatingCurrentBook()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!viewModel.hasSource)

                Button(
                    viewModel.isEditingTranslations
                        ? String(localized: "Done Editing Balloons", bundle: .localized)
                        : String(localized: "Edit Balloons", bundle: .localized)
                ) {
                    viewModel.toggleEditingTranslations()
                }
                // Not ⌘E: that's the system's Use Selection for Find.
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!viewModel.isEditingTranslations && !viewModel.canEditTranslations)

                Button(String(localized: "Show Hidden Balloons", bundle: .localized)) {
                    viewModel.translationEdits.showAllHidden()
                }
                .disabled(viewModel.translationEdits.hiddenCount == 0)

                Divider()
            }
        }
    }
}
