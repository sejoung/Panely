import Foundation
import Logging
import Testing
@testable import Panely

/// Level gating in `AppLog`: below the configured level nothing about the
/// event is built (callers' messages and metadata are autoclosures that may
/// stat files), and a level change in Settings applies to the very next
/// call. These live in `AppLogTests` (serialized) because the level is
/// process-wide state that `metadataIsWrittenToDiagnosticLogStore` also
/// changes. The previous stored value — including "never set" — is put back
/// exactly afterwards.
extension AppLogTests {

    @Test func messageAndMetadataAreOnlyBuiltForEventsThatPassTheLevel() {
        withLogLevel(.warning) {
            let probe = EvaluationProbe()
            AppLog.trace(.diagnostics, probe.message(), metadata: probe.metadata())
            AppLog.debug(.diagnostics, probe.message(), metadata: probe.metadata())
            AppLog.info(.diagnostics, probe.message(), metadata: probe.metadata())
            AppLog.notice(.diagnostics, probe.message(), metadata: probe.metadata())
            #expect(probe.messages == 0)
            #expect(probe.metadataBuilds == 0)

            AppLog.warning(.diagnostics, probe.message(), metadata: probe.metadata())
            AppLog.error(.diagnostics, probe.message(), metadata: probe.metadata())
            #expect(probe.messages == 2)
            #expect(probe.metadataBuilds == 2)
        }
    }

    @Test func levelChangeAppliesToTheNextCall() async throws {
        let token = "level-change-\(UUID().uuidString)"
        try await withLogLevel(.error) {
            AppLog.info(.diagnostics, "suppressed \(token)")
            DiagnosticLogConfiguration.setCurrentLogLevel(.info)
            AppLog.info(.diagnostics, "written \(token)")

            let log = try await recentLogText(containing: "written \(token)")
            #expect(log.contains("written \(token)"))
            // FIFO: the earlier call would have landed first.
            #expect(!log.contains("suppressed \(token)"))
        }
    }

    // MARK: - Helpers

    private func withLogLevel<T>(_ level: DiagnosticLogLevel, _ body: () async throws -> T) async rethrows -> T {
        let key = DiagnosticLogConfiguration.logLevelKey
        let saved = UserDefaults.standard.object(forKey: key)
        DiagnosticLogConfiguration.setCurrentLogLevel(level)
        defer { restore(saved, forKey: key) }
        return try await body()
    }

    private func withLogLevel<T>(_ level: DiagnosticLogLevel, _ body: () throws -> T) rethrows -> T {
        let key = DiagnosticLogConfiguration.logLevelKey
        let saved = UserDefaults.standard.object(forKey: key)
        DiagnosticLogConfiguration.setCurrentLogLevel(level)
        defer { restore(saved, forKey: key) }
        return try body()
    }

    private func restore(_ saved: Any?, forKey key: String) {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func recentLogText(containing needle: String) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let log = await DiagnosticLogStore.shared.recentLogText()
            if log.contains(needle) { return log }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await DiagnosticLogStore.shared.recentLogText()
    }
}

private final class EvaluationProbe {
    private(set) var messages = 0
    private(set) var metadataBuilds = 0

    func message() -> String {
        messages += 1
        return "probe"
    }

    func metadata() -> AppLog.Metadata {
        metadataBuilds += 1
        return ["probe": "yes"]
    }
}
