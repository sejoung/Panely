import Foundation
import Testing
import ZIPFoundation
@testable import Panely

@MainActor
struct DiagnosticReportExporterTests {
    @Test func redactorDoesNotExposeParentPath() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Vol 01.cbz")
        try Fixture.writeFile(url)

        let description = DiagnosticRedactor.describe(url)

        #expect(description.contains("Vol 01.cbz"))
        #expect(description.contains(dir.path) == false)
        #expect(description.contains("ext=cbz"))
        #expect(description.contains("type=file"))
    }

    @Test func exportWritesReportZipWithRedactedDiagnostics() async throws {
        let cache = TestExtractionCacheManager(cacheBudgetBytes: 1_024)
        let vm = makeTestViewModel(extractionCache: cache)
        vm.errorMessage = "Sample load failure"
        vm.currentSourceURL = URL(fileURLWithPath: "/Users/example/Comics/Vol 02.cbz")
        vm.openedSourceURL = vm.currentSourceURL
        vm.explicitLibraryRootURL = URL(fileURLWithPath: "/Users/example/Comics", isDirectory: true)

        await DiagnosticLogStore.shared.record(
            level: .info,
            category: .load,
            message: "Load started source=\(DiagnosticRedactor.describe(vm.currentSourceURL))"
        )

        let outputDir = try Fixture.makeTempDir()
        let unzipDir = try Fixture.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: unzipDir)
        }
        let destination = outputDir.appendingPathComponent("diagnostic-report.zip")
        let exporter = DiagnosticReportExporter(
            viewModel: vm,
            cacheMaintenance: CacheMaintenance(extractionCache: cache)
        )

        try await exporter.exportReport(to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.unzipItem(at: destination, to: unzipDir)

        let reportURL = unzipDir.appendingPathComponent("diagnostic-report.md")
        let logURL = unzipDir.appendingPathComponent("recent-log.txt")
        let eventsURL = unzipDir.appendingPathComponent("recent-load-events.txt")
        let report = try String(contentsOf: reportURL, encoding: .utf8)
        let events = try String(contentsOf: eventsURL, encoding: .utf8)

        #expect(FileManager.default.fileExists(atPath: logURL.path))
        #expect(report.contains("# Panely Diagnostic Report"))
        #expect(report.contains("Sample load failure"))
        #expect(report.contains("Extraction cache"))
        #expect(report.contains("name=Vol 02.cbz"))
        #expect(report.contains("/Users/example/Comics") == false)
        #expect(events.contains("name=Vol 02.cbz"))
        #expect(events.contains("/Users/example/Comics") == false)
    }

    @Test func exportRedactsKnownPathsFromLastError() async throws {
        let cache = TestExtractionCacheManager(cacheBudgetBytes: 1_024)
        let vm = makeTestViewModel(extractionCache: cache)
        vm.currentSourceURL = URL(fileURLWithPath: "/Users/example/Comics/Vol 03.cbz")
        vm.openedSourceURL = vm.currentSourceURL
        vm.errorMessage = "Could not read /Users/example/Comics/Vol 03.cbz"

        let outputDir = try Fixture.makeTempDir()
        let unzipDir = try Fixture.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: unzipDir)
        }
        let destination = outputDir.appendingPathComponent("diagnostic-report.zip")
        let exporter = DiagnosticReportExporter(
            viewModel: vm,
            cacheMaintenance: CacheMaintenance(extractionCache: cache)
        )

        try await exporter.exportReport(to: destination)
        try FileManager.default.unzipItem(at: destination, to: unzipDir)

        let reportURL = unzipDir.appendingPathComponent("diagnostic-report.md")
        let report = try String(contentsOf: reportURL, encoding: .utf8)

        #expect(report.contains("Could not read <redacted-path>"))
        #expect(report.contains("/Users/example/Comics") == false)
    }
}
