import AppKit
import SwiftUI

extension PanelyApp {
    /// Replaces the default File ▸ New item with Open… plus a Recent
    /// submenu that resolves security-scoped bookmarks the same way
    /// drag-drop does.
    @CommandsBuilder
    var fileCommands: some Commands {
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

            Divider()

            SettingsLink {
                Text("Storage Settings…")
            }

            Button("Clear Extraction Cache") {
                let activeURL = viewModel.tempDir.url
                Task {
                    let removedBytes = await Task.detached(priority: .utility) {
                        ReaderTempDirectory.clearCache(excluding: activeURL)
                    }.value
                    presentCacheClearResult(removedBytes: removedBytes)
                }
            }
            .disabled(viewModel.isLoading)
        }
    }
}

/// File-menu cache cleanup runs in the background; this modal gives the user a
/// visible result when the menu action completes.
@MainActor
func presentCacheClearResult(removedBytes: UInt64) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")

    if removedBytes > 0 {
        alert.messageText = "Extraction Cache Cleared"
        alert.informativeText = "\(formatCacheBytes(removedBytes)) was removed."
    } else {
        alert.messageText = "No Extraction Cache Cleared"
        alert.informativeText = "There is no inactive extraction cache to remove."
    }

    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        alert.beginSheetModal(for: window)
    } else {
        alert.runModal()
    }
}

private func formatCacheBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
}
