import Foundation
import Logging
import Testing
@testable import Panely

struct AppLogTests {
    @Test func metadataIsWrittenToDiagnosticLogStore() async throws {
        let token = "app-log-test-\(UUID().uuidString)"

        AppLog.notice(
            .diagnostics,
            "Metadata facade test",
            metadata: [
                "token": "\(token)",
                "value": "line one\nline two",
            ]
        )

        let log = try await recentLogText(containing: token)

        #expect(log.contains("Metadata facade test"))
        #expect(log.contains("[NOTICE] [diagnostics]"))
        #expect(log.contains("token=\(token)"))
        #expect(log.contains("value=line one line two"))
    }

    private func recentLogText(containing token: String) async throws -> String {
        for _ in 0..<20 {
            let log = await DiagnosticLogStore.shared.recentLogText()
            if log.contains(token) {
                return log
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return await DiagnosticLogStore.shared.recentLogText()
    }
}
