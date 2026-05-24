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
                Task {
                    await DiagnosticLogStore.shared.clear()
                    DiagnosticReportExporter.presentClearLogsResult()
                }
            }

            Button("Clear Extraction Cache") {
                let activeURL = viewModel.tempDir.url
                let cacheMaintenance = CacheMaintenance(extractionCache: viewModel.dependencies.extractionCache)
                AppLog.info(
                    .cache,
                    "Clear extraction cache requested from File menu",
                    metadata: ["activeURL": "\(DiagnosticRedactor.describe(activeURL))"]
                )
                Task {
                    let removedBytes = await Task.detached(priority: .utility) {
                        cacheMaintenance.clearExtractionCache(excluding: activeURL)
                    }.value
                    cacheMaintenance.presentClearResult(removedBytes: removedBytes)
                }
            }
            .disabled(viewModel.isLoading)
        }
    }
}
