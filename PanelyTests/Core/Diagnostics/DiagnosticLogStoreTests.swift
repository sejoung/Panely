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
