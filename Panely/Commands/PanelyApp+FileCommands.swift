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

            Button("Reload Book") {
                viewModel.reloadCurrentSource()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(viewModel.currentSourceURL == nil || viewModel.isLoading)

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
                Text("Settings…")
            }

            Divider()

            Button("Export Diagnostic Report…") {
                let exporter = DiagnosticReportExporter(viewModel: viewModel)
                guard let destination = exporter.selectDestination() else { return }
                Task {
                    do {
                        try await exporter.exportReport(to: destination)
                        exporter.presentExportResult(destination: destination)
                    } catch {
                        exporter.presentExportFailure(error, destination: destination)
                    }
                }
            }

            Button("Clear Diagnostic Logs") {
                guard DiagnosticReportExporter.confirmClearLogs() else { return }
                Task {
                    let cleared = await DiagnosticLogStore.shared.clear()
                    DiagnosticReportExporter.presentClearLogsResult(success: cleared)
                }
            }

            Button("Open Diagnostic Logs Folder") {
                DiagnosticReportExporter.openDiagnosticsFolder()
            }

            Button("Clear Extraction Cache") {
                viewModel.clearExtractionCache()
            }
            .disabled(viewModel.isLoading)
        }
    }
}
