import SwiftUI

extension PanelyApp {
    /// The View menu: chrome toggles → layout → fit → zoom → auto-fit
    /// lock, separated by dividers in that order so keyboard shortcuts
    /// cluster by intent (`⌃⌘X` chrome, `⇧⌘1-3` layout, `⌘1-3` fit,
    /// `⌘+/-/0` zoom).
    @CommandsBuilder
    var viewCommands: some Commands {
        CommandMenu("View") {
            Button(viewModel.sidebarPinned ? "Unpin Library" : "Pin Library") {
                viewModel.toggleSidebarPin()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])

            Button(viewModel.toolbarPinned ? "Unpin Toolbar" : "Pin Toolbar") {
                viewModel.toggleToolbarPin()
            }
            .keyboardShortcut("t", modifiers: [.control, .command])

            Button(viewModel.thumbnailSidebarVisible ? "Hide Thumbnails" : "Show Thumbnails") {
                viewModel.toggleThumbnailSidebar()
            }
            .keyboardShortcut("p", modifiers: [.control, .command])
            .disabled(!viewModel.hasSource)

            Divider()

            Button("Single Page") {
                viewModel.setLayout(.single)
            }
            .keyboardShortcut("1", modifiers: [.command, .shift])
            .disabled(viewModel.layout == .single)

            Button("Double Page") {
                viewModel.setLayout(.double)
            }
            .keyboardShortcut("2", modifiers: [.command, .shift])
            .disabled(viewModel.layout == .double)

            Button("Vertical Scroll") {
                viewModel.setLayout(.vertical)
            }
            .keyboardShortcut("3", modifiers: [.command, .shift])
            .disabled(viewModel.layout == .vertical)

            Divider()

            Button("Fit to Screen") {
                viewModel.setFitMode(.fitScreen)
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(viewModel.fitMode == .fitScreen)

            Button("Fit to Width") {
                viewModel.setFitMode(.fitWidth)
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(viewModel.fitMode == .fitWidth)

            Button("Fit to Height") {
                viewModel.setFitMode(.fitHeight)
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(viewModel.fitMode == .fitHeight)

            Divider()

            Button("Zoom In") {
                viewerController.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Zoom Out") {
                viewerController.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Reset Zoom") {
                viewerController.resetZoom()
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()

            Button(viewModel.autoFitOnResize ? "Lock View Size" : "Unlock View Size") {
                viewModel.toggleAutoFitOnResize()
            }
            .keyboardShortcut("l", modifiers: .command)
        }
    }
}
