import AppKit
import SwiftUI

@MainActor
struct DiagnosticsSettingsView: View {
    let viewModel: ReaderViewModel
    let exporter: DiagnosticReportExporter

    @State private var isExporting = false
    @State private var exportMessage: String?

    init(
        viewModel: ReaderViewModel,
        exporter: DiagnosticReportExporter? = nil
    ) {
        self.viewModel = viewModel
        self.exporter = exporter ?? DiagnosticReportExporter(viewModel: viewModel)
    }

    var body: some View {
        Form {
            Section("Diagnostics") {
                LabeledContent("App version") {
                    Text(appVersionText)
                        .monospacedDigit()
                }

                LabeledContent("macOS") {
                    Text(ProcessInfo.processInfo.operatingSystemVersionString)
                }

                HStack {
                    Button("Export Diagnostic Report…") {
                        exportDiagnosticReport()
                    }
                    .disabled(isExporting)

                    Button("Clear Diagnostic Logs") {
                        clearDiagnosticLogs()
                    }
                    .disabled(isExporting)

                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 12)
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private func exportDiagnosticReport() {
        guard let url = exporter.selectDestination() else { return }

        isExporting = true
        exportMessage = nil
        Task {
            do {
                try await exporter.exportReport(to: url)
                exportMessage = "Diagnostic report exported."
            } catch {
                let message = DiagnosticRedactor.redactKnownPaths(
                    in: error.localizedDescription,
                    urls: [url]
                )
                AppLog.error(
                    .diagnostics,
                    "Diagnostic report export failed",
                    metadata: ["error": "\(message)"]
                )
                exportMessage = "Export failed: \(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    private func clearDiagnosticLogs() {
        Task {
            await DiagnosticLogStore.shared.clear()
            exportMessage = "Diagnostic logs cleared."
        }
    }
}

#Preview {
    DiagnosticsSettingsView(viewModel: ReaderViewModel())
        .preferredColorScheme(.dark)
}
