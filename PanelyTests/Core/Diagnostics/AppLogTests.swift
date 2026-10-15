import Foundation
import Logging
import Testing
@testable import Panely

@Suite(.serialized)
struct AppLogTests {
    @Test func metadataIsWrittenToDiagnosticLogStore() async throws {
        let token = "app-log-test-\(UUID().uuidString)"
        let previousLevel = DiagnosticLogConfiguration.currentLogLevel
        DiagnosticLogConfiguration.setCurrentLogLevel(.trace)
        defer {
            DiagnosticLogConfiguration.setCurrentLogLevel(previousLevel)
        }

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
        // Writing goes through the logger's own queue; poll with a generous
        // deadline (see `waitUntil`) — a passing run returns on the first hit.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let log = await DiagnosticLogStore.shared.recentLogText()
            if log.contains(token) {
                return log
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await DiagnosticLogStore.shared.recentLogText()
    }
}
