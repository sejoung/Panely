import SwiftUI

@main
struct PanelyApp: App {
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
        .commands {
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
}
