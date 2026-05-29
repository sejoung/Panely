import AppKit
import Foundation
import UniformTypeIdentifiers
import ZIPFoundation

/// Orchestrates diagnostic-report export: pick a destination, build the
/// snapshot (`DiagnosticSnapshotBuilder`), and write the zip
/// (`DiagnosticReportWriter`). Presentation lives in `DiagnosticReportAlerts`;
/// this type performs no UI of its own.
@MainActor
struct DiagnosticReportExporter {
    let viewModel: ReaderViewModel
    let cacheMaintenance: CacheMaintenance

    init(
        viewModel: ReaderViewModel,
        cacheMaintenance: CacheMaintenance? = nil
    ) {
        self.viewModel = viewModel
        self.cacheMaintenance = cacheMaintenance
            ?? CacheMaintenance(extractionCache: viewModel.dependencies.extractionCache)
    }

    func defaultFileName() -> String {
        let date = Self.fileDateFormatter.string(from: Date())
        return "Panely-Diagnostic-Report-\(date).zip"
    }

    func selectDestination() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultFileName()
        return panel.runModal() == .OK ? panel.url : nil
    }

    func exportReport(to destination: URL) async throws {
        AppLog.info(
            .diagnostics,
            "Export diagnostic report requested",
            metadata: ["destination": "\(DiagnosticRedactor.describe(destination))"]
        )
        let snapshot = await DiagnosticSnapshotBuilder(
            viewModel: viewModel,
            cacheMaintenance: cacheMaintenance
        ).makeSnapshot()
        try await Task.detached(priority: .utility) {
            try DiagnosticReportWriter.write(snapshot: snapshot, to: destination)
        }.value
        AppLog.info(
            .diagnostics,
            "Diagnostic report exported",
            metadata: ["destination": "\(DiagnosticRedactor.describe(destination))"]
        )
    }

    static func formattedBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

/// All user-facing AppKit alerts for diagnostics actions. Kept apart from the
/// exporter so report building stays free of presentation concerns (and so the
/// export path can run without an `NSApp`).
@MainActor
enum DiagnosticReportAlerts {
    static func presentExportResult(destination: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Diagnostic Report Exported"
        alert.informativeText = "\(destination.lastPathComponent) was created."
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "OK")
        present(alert) { response in
            if response == .alertFirstButtonReturn {
                revealInFinder(destination)
            }
        }
    }

    static func presentExportFailure(_ error: Error, destination: URL) {
        let message = DiagnosticRedactor.redactKnownPaths(
            in: error.localizedDescription,
            urls: [destination]
        )
        AppLog.error(
            .diagnostics,
            "Diagnostic report export failed",
            metadata: ["error": "\(message)"]
        )

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Diagnostic Report Export Failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    static func presentClearLogsResult(success: Bool) {
        let alert = NSAlert()
        if success {
            alert.alertStyle = .informational
            alert.messageText = "Diagnostic Logs Cleared"
            alert.informativeText = "Recent file logs were removed."
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Could Not Clear Diagnostic Logs"
            alert.informativeText = "The recent file log could not be removed. Please try again."
        }
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    static func confirmClearLogs() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear Diagnostic Logs?"
        alert.informativeText = "This removes Panely's recent file log. It does not clear OSLog, cache data, recent files, bookmarks, favorites, or reading position."
        alert.addButton(withTitle: "Clear Logs")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func openDiagnosticsFolder() {
        Task {
            let url = await DiagnosticLogStore.shared.ensureDiagnosticsDirectory()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static func present(
        _ alert: NSAlert,
        completion: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                completion?(response)
            }
        } else {
            let response = alert.runModal()
            completion?(response)
        }
    }

    private static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Gathers app / session / cache / reader / log state into a
/// `DiagnosticReportSnapshot`. Pure data collection — no AppKit alerts — so it
/// runs on the export path (and is exercised by the export test) without any
/// presentation dependency.
@MainActor
private struct DiagnosticSnapshotBuilder {
    let viewModel: ReaderViewModel
    let cacheMaintenance: CacheMaintenance

    func makeSnapshot() async -> DiagnosticReportSnapshot {
        let activeURL = viewModel.tempDir.url
        let cacheRoot = cacheMaintenance.cacheRoot()
        let cacheMaintenance = cacheMaintenance
        let cacheSizes = await Task.detached(priority: .utility) {
            cacheMaintenance.cacheSizes(in: cacheRoot, excluding: activeURL)
        }.value

        let logText = await DiagnosticLogStore.shared.recentLogText()
        let loadEvents = await DiagnosticLogStore.shared.recentEvents(
            categories: [.load, .library],
            maxLines: 120
        )

        return DiagnosticReportSnapshot(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: Self.bundleString("CFBundleShortVersionString"),
            buildNumber: Self.bundleString("CFBundleVersion"),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            sessionID: DiagnosticSession.id,
            launchedAt: DiagnosticSession.launchedAt,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            cacheTotal: cacheMaintenance.formattedBytes(cacheSizes.total),
            cacheClearable: cacheMaintenance.formattedBytes(cacheSizes.clearable),
            cacheLimit: cacheMaintenance.formattedBytes(cacheMaintenance.cacheBudgetBytes),
            logLevel: DiagnosticLogConfiguration.currentLogLevel.displayName,
            logFileSize: cacheMaintenance.formattedBytes(await DiagnosticLogStore.shared.logSizeBytes()),
            logFileLimit: cacheMaintenance.formattedBytes(DiagnosticLogPolicy.maxLogBytes),
            reportLogLimit: cacheMaintenance.formattedBytes(DiagnosticLogPolicy.reportLogBytes),
            settingsSummary: settingsSummary(),
            readerSummary: readerSummary(),
            lastErrorMessage: redactKnownPaths(in: viewModel.errorMessage ?? "None"),
            recentLogText: logText,
            recentLoadEventsText: loadEvents.isEmpty ? "No recent load events recorded." : loadEvents
        )
    }

    private func settingsSummary() -> String {
        """
        layout: \(viewModel.layout.rawValue)
        direction: \(viewModel.direction.rawValue)
        fitMode: \(viewModel.fitMode.rawValue)
        autoFitOnResize: \(viewModel.autoFitOnResize)
        diagnosticLogLevel: \(DiagnosticLogConfiguration.currentLogLevel.displayName)
        sidebarPinned: \(viewModel.sidebarPinned)
        toolbarPinned: \(viewModel.toolbarPinned)
        thumbnailSidebarVisible: \(viewModel.thumbnailSidebarVisible)
        """
    }

    private func readerSummary() -> String {
        """
        hasSource: \(viewModel.hasSource)
        sourceTitle: \(viewModel.source.title)
        currentPage: \(viewModel.currentPageNumber)
        totalPages: \(viewModel.totalPages)
        isLoading: \(viewModel.isLoading)
        loadingMessage: \(viewModel.loadingMessage)
        currentSource: \(DiagnosticRedactor.describe(viewModel.currentSourceURL))
        openedSource: \(DiagnosticRedactor.describe(viewModel.openedSourceURL))
        libraryRoot: \(DiagnosticRedactor.describe(viewModel.libraryRootURL))
        siblings: \(viewModel.siblings.count)
        """
    }

    private static func bundleString(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }

    private func redactKnownPaths(in text: String) -> String {
        guard text.isEmpty == false else { return text }

        return DiagnosticRedactor.redactKnownPaths(in: text, urls: [
            viewModel.currentSourceURL,
            viewModel.openedSourceURL,
            viewModel.libraryRootURL,
            viewModel.tempDir.url,
            cacheMaintenance.cacheRoot(),
        ])
    }
}

private nonisolated struct DiagnosticReportSnapshot: Sendable {
    let generatedAt: String
    let appVersion: String
    let buildNumber: String
    let bundleIdentifier: String
    let sessionID: String
    let launchedAt: String
    let macOSVersion: String
    let cacheTotal: String
    let cacheClearable: String
    let cacheLimit: String
    let logLevel: String
    let logFileSize: String
    let logFileLimit: String
    let reportLogLimit: String
    let settingsSummary: String
    let readerSummary: String
    let lastErrorMessage: String
    let recentLogText: String
    let recentLoadEventsText: String

    var reportMarkdown: String {
        """
        # Panely Diagnostic Report

        Generated: \(generatedAt)

        ## App

        - Version: \(appVersion)
        - Build: \(buildNumber)
        - Bundle ID: \(bundleIdentifier)
        - macOS: \(macOSVersion)

        ## Session

        - Session ID: \(sessionID)
        - App launched: \(launchedAt)

        ## Cache

        - Extraction cache: \(cacheTotal)
        - Clearable cache: \(cacheClearable)
        - Cache limit: \(cacheLimit)

        ## Diagnostics

        - Log level: \(logLevel)
        - File log size: \(logFileSize)
        - File log limit: \(logFileLimit)
        - Report log limit: \(reportLogLimit)

        ## Current Settings

        ```text
        \(settingsSummary)
        ```

        ## Reader State

        ```text
        \(readerSummary)
        ```

        ## Last Error

        ```text
        \(lastErrorMessage)
        ```

        ## Privacy

        File paths are redacted to filename, extension, and type where Panely writes diagnostic events.
        The recent log file may include error text produced by the app or system frameworks.
        """
    }
}

private nonisolated enum DiagnosticReportWriter {
    static func write(snapshot: DiagnosticReportSnapshot, to destination: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("panely-diagnostic-report-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(snapshot.reportMarkdown.utf8)
            .write(to: staging.appendingPathComponent("diagnostic-report.md"))
        try Data(snapshot.recentLogText.utf8)
            .write(to: staging.appendingPathComponent("recent-log.txt"))
        try Data(snapshot.recentLoadEventsText.utf8)
            .write(to: staging.appendingPathComponent("recent-load-events.txt"))

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.zipItem(at: staging, to: destination, shouldKeepParent: false)
    }
}
