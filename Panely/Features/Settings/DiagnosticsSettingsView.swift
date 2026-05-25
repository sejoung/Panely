import AppKit
import SwiftUI

@MainActor
struct DiagnosticsSettingsView: View {
    let viewModel: ReaderViewModel
    let exporter: DiagnosticReportExporter

    @State private var isExporting = false
    @State private var exportMessage: String?
    @State private var logSizeBytes: UInt64?
    @State private var selectedLogLevel = DiagnosticLogConfiguration.currentLogLevel

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

                LabeledContent("Session") {
                    Text(String(DiagnosticSession.id.prefix(8)))
                        .monospaced()
                }

                LabeledContent("File log") {
                    if let logSizeBytes {
                        Text(DiagnosticReportExporter.formattedBytes(logSizeBytes))
                            .monospacedDigit()
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                LabeledContent("Retention") {
                    Text("\(DiagnosticReportExporter.formattedBytes(DiagnosticLogPolicy.maxLogBytes)) max, reports include \(DiagnosticReportExporter.formattedBytes(DiagnosticLogPolicy.reportLogBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Log level", selection: $selectedLogLevel) {
                    ForEach(DiagnosticLogLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Export Diagnostic Report…") {
                            exportDiagnosticReport()
                        }
                        .disabled(isExporting)

                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    HStack {
                        Button("Clear Diagnostic Logs") {
                            clearDiagnosticLogs()
                        }
                        .disabled(isExporting)

                        Button("Open Logs Folder") {
                            DiagnosticReportExporter.openDiagnosticsFolder()
                        }
                        .disabled(isExporting)
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
        .frame(width: 560)
        .padding(.vertical, 12)
        .task {
            await refreshLogSize()
        }
        .onChange(of: selectedLogLevel) { _, newValue in
            DiagnosticLogConfiguration.setCurrentLogLevel(newValue)
            exportMessage = "Diagnostic log level set to \(newValue.displayName)."
        }
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
            await refreshLogSize()
        }
    }

    private func clearDiagnosticLogs() {
        guard DiagnosticReportExporter.confirmClearLogs() else { return }
        Task {
            await DiagnosticLogStore.shared.clear()
            await refreshLogSize()
            exportMessage = "Diagnostic logs cleared."
        }
    }

    private func refreshLogSize() async {
        logSizeBytes = await DiagnosticLogStore.shared.logSizeBytes()
    }
}

#Preview {
    DiagnosticsSettingsView(viewModel: ReaderViewModel())
        .preferredColorScheme(.dark)
}
