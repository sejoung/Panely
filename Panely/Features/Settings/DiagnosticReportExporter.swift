import AppKit
import Foundation
import ZIPFoundation

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

    func exportReport(to destination: URL) async throws {
        AppLog.info(
            .diagnostics,
            "Export diagnostic report requested",
            metadata: ["destination": "\(DiagnosticRedactor.describe(destination))"]
        )
        let snapshot = await makeSnapshot()
        try await Task.detached(priority: .utility) {
            try DiagnosticReportWriter.write(snapshot: snapshot, to: destination)
        }.value
        AppLog.info(
            .diagnostics,
            "Diagnostic report exported",
            metadata: ["destination": "\(DiagnosticRedactor.describe(destination))"]
        )
    }

    private func makeSnapshot() async -> DiagnosticReportSnapshot {
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
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            cacheTotal: cacheMaintenance.formattedBytes(cacheSizes.total),
            cacheClearable: cacheMaintenance.formattedBytes(cacheSizes.clearable),
            cacheLimit: cacheMaintenance.formattedBytes(cacheMaintenance.cacheBudgetBytes),
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

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private nonisolated struct DiagnosticReportSnapshot: Sendable {
    let generatedAt: String
    let appVersion: String
    let buildNumber: String
    let bundleIdentifier: String
    let macOSVersion: String
    let cacheTotal: String
    let cacheClearable: String
    let cacheLimit: String
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

        ## Cache

        - Extraction cache: \(cacheTotal)
        - Clearable cache: \(cacheClearable)
        - Cache limit: \(cacheLimit)

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
