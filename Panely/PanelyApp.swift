import AppKit
import SwiftUI

@main
struct PanelyApp: App {
    @NSApplicationDelegateAdaptor(PanelyAppDelegate.self) private var appDelegate
    @State private var viewModel = ReaderViewModel()
    @State private var viewerController = ViewerController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .environment(viewerController)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { panelyCommands }
    }

    @CommandsBuilder
    private var panelyCommands: some Commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    viewModel.openSource()
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    if viewModel.recentItems.items.isEmpty {
                        Text("No Recent Items")
                    } else {
                        ForEach(viewModel.recentItems.items) { item in
                            Button {
                                if let url = viewModel.recentItems.resolve(item) {
                                    viewModel.openURL(url)
                                }
                            } label: {
                                Label(item.title, systemImage: item.iconName)
                            }
                        }
                        Divider()
                        Button("Clear Menu") {
                            viewModel.recentItems.clear()
                        }
                    }
                }
            }

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

                Button("Fit to Screen") {
                    viewModel.fitMode = .fitScreen
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(viewModel.fitMode == .fitScreen)

                Button("Fit to Width") {
                    viewModel.fitMode = .fitWidth
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(viewModel.fitMode == .fitWidth)

                Button("Fit to Height") {
                    viewModel.fitMode = .fitHeight
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

            CommandMenu("Go") {
                Button("Go to Page…") {
                    promptJumpToPage(viewModel: viewModel)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!viewModel.hasSource || viewModel.totalPages <= 1)

                Divider()

                Button(viewModel.isCurrentPageBookmarked ? "Remove Page Bookmark" : "Add Page Bookmark") {
                    viewModel.toggleCurrentPageBookmark()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!viewModel.hasSource)

                Button("Previous Bookmark") {
                    viewModel.jumpToPreviousBookmark()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(!viewModel.canGoPreviousBookmark)

                Button("Next Bookmark") {
                    viewModel.jumpToNextBookmark()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(!viewModel.canGoNextBookmark)

                Divider()

                Button(viewModel.isCurrentBookFavorite ? "Remove from Favorites" : "Add to Favorites") {
                    viewModel.toggleFavoriteForCurrentBook()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!viewModel.hasSource)

                Divider()

                Button("Previous Volume") {
                    viewModel.previousVolume()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!viewModel.canGoPreviousVolume)

                Button("Next Volume") {
                    viewModel.nextVolume()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!viewModel.canGoNextVolume)
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

@MainActor
private func promptJumpToPage(viewModel: ReaderViewModel) {
    guard viewModel.hasSource, viewModel.totalPages > 1 else { return }

    let alert = NSAlert()
    alert.messageText = "Go to Page"
    alert.informativeText = "Enter a page number (1 – \(viewModel.totalPages)):"
    alert.addButton(withTitle: "Go")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    field.placeholderString = "\(viewModel.currentPageNumber)"
    field.stringValue = "\(viewModel.currentPageNumber)"
    field.alignment = .center
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
    guard let parsed = Int(trimmed) else { return }
    viewModel.jump(toPageNumber: parsed)
}
