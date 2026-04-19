import SwiftUI

@main
struct PanelyApp: App {
    @State private var viewModel = ReaderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
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
                Button(viewModel.sidebarVisible ? "Hide Library" : "Show Library") {
                    viewModel.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])

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
