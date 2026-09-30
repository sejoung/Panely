import SwiftUI

extension PanelyApp {
    /// Replaces the default File ▸ New item with Open… plus a Recent
    /// submenu that resolves security-scoped bookmarks the same way
    /// drag-drop does.
    @CommandsBuilder
    var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Open…", bundle: .localized)) {
                viewModel.openSource()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button(String(localized: "Reload Book", bundle: .localized)) {
                viewModel.reloadCurrentSource()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(viewModel.currentSourceURL == nil || viewModel.isLoading)

            Menu(String(localized: "Open Recent", bundle: .localized)) {
                if viewModel.recentItems.menuItems.isEmpty {
                    Text(String(localized: "No Recent Items", bundle: .localized))
                } else {
                    ForEach(viewModel.recentItems.menuItems) { item in
                        Button {
                            viewModel.openRecentItem(item)
                        } label: {
                            Label(item.title, systemImage: item.iconName)
                        }
                    }
                    Divider()
                    Button(String(localized: "Clear Menu", bundle: .localized)) {
                        viewModel.recentItems.clear()
                    }
                }
            }

            Divider()

            SettingsLink {
                Text(String(localized: "Settings…", bundle: .localized))
            }

            Divider()

            Button(String(localized: "Export Diagnostic Report…", bundle: .localized)) {
                let exporter = DiagnosticReportExporter(viewModel: viewModel)
                guard let destination = exporter.selectDestination() else { return }
                Task {
                    do {
                        try await exporter.exportReport(to: destination)
                        DiagnosticReportAlerts.presentExportResult(destination: destination)
                    } catch {
                        DiagnosticReportAlerts.presentExportFailure(error, destination: destination)
                    }
                }
            }

            Button(String(localized: "Clear Diagnostic Logs", bundle: .localized)) {
                guard DiagnosticReportAlerts.confirmClearLogs() else { return }
                Task {
                    let cleared = await DiagnosticLogStore.shared.clear()
                    DiagnosticReportAlerts.presentClearLogsResult(success: cleared)
                }
            }

            Button(String(localized: "Open Diagnostic Logs Folder", bundle: .localized)) {
                DiagnosticReportAlerts.openDiagnosticsFolder()
            }

            Button(String(localized: "Clear Extraction Cache", bundle: .localized)) {
                viewModel.clearExtractionCache()
            }
            .disabled(viewModel.isLoading)
        }
    }
}
