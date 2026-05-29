import Foundation
import Testing
@testable import Panely

struct DiagnosticLogStoreTests {
    @Test func testRunsUseSeparateDiagnosticLogDirectory() async {
        let url = await DiagnosticLogStore.shared.logFileURL()

        #expect(url.path.contains("panely-diagnostics-tests"))
        #expect(url.path.contains("panely-diagnostics/recent-log.txt") == false)
    }

    @Test func logPolicyIsBoundedForDiagnosticReports() {
        #expect(DiagnosticLogPolicy.maxLogBytes == 768 * 1024)
        #expect(DiagnosticLogPolicy.trimToBytes == 384 * 1024)
        #expect(DiagnosticLogPolicy.reportLogBytes == 256 * 1024)
    }

    @Test func clearReportsSuccessAndRemovesLogFile() async throws {
        let store = DiagnosticLogStore(directoryName: "panely-diagnostics-\(UUID().uuidString)")
        let url = await store.logFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // No file yet — clearing is still a success (nothing to remove).
        let clearedEmpty = await store.clear()
        #expect(clearedEmpty == true)

        await store.record(level: .info, category: .app, message: "hello")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let cleared = await store.clear()
        #expect(cleared == true)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test func recentEventsMatchesCategoryPositionallyNotMessageBody() async throws {
        let store = DiagnosticLogStore(directoryName: "panely-diagnostics-\(UUID().uuidString)")
        let url = await store.logFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // An `app` line whose message body mentions "[load]" must NOT be
        // mistaken for a `load` event; the real `load` line must be included.
        await store.record(level: .info, category: .app, message: "saw marker [load] in text")
        await store.record(level: .info, category: .load, message: "actually loading")

        let events = await store.recentEvents(categories: [.load])
        #expect(events.contains("actually loading"))
        #expect(events.contains("saw marker [load] in text") == false)
    }

    @Test func recentLogTextToleratesTruncatedUTF8Boundary() async throws {
        let store = DiagnosticLogStore(directoryName: "panely-diagnostics-\(UUID().uuidString)")
        let url = await store.logFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data([0xEA]).write(to: url)

        let text = await store.recentLogText(maxBytes: 1)

        #expect(text.isEmpty == false)
    }
}
