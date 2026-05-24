import Foundation

actor DiagnosticLogStore {
    static let shared = DiagnosticLogStore()

    private let maxLogBytes: UInt64 = 768 * 1024
    private let logFileName = "recent-log.txt"
    private nonisolated static let productionDirectoryName = "panely-diagnostics"
    private nonisolated static let testDirectoryName = "panely-diagnostics-tests"

    nonisolated static func record(
        level: DiagnosticLevel,
        category: DiagnosticCategory,
        message: String
    ) {
        Task.detached(priority: .utility) {
            await shared.record(level: level, category: category, message: message)
        }
    }

    func record(level: DiagnosticLevel, category: DiagnosticCategory, message: String) {
        append(level: level, category: category, message: message)
    }

    func logFileURL() -> URL {
        diagnosticsDirectory().appendingPathComponent(logFileName)
    }

    func recentLogText(maxBytes: Int = 256 * 1024) -> String {
        let url = logFileURL()
        guard let data = try? Data(contentsOf: url) else { return "" }
        let slice: Data
        if data.count > maxBytes {
            slice = data.suffix(maxBytes)
        } else {
            slice = data
        }
        return String(data: slice, encoding: .utf8) ?? ""
    }

    func recentEvents(categories: Set<DiagnosticCategory>, maxLines: Int = 100) -> String {
        let lines = recentLogText().split(separator: "\n", omittingEmptySubsequences: false)
        let markers = categories.map { "[\($0.rawValue)]" }
        let filtered = lines.filter { line in
            markers.contains { line.contains($0) }
        }
        return filtered.suffix(maxLines).joined(separator: "\n")
    }

    func clear() {
        try? FileManager.default.removeItem(at: logFileURL())
    }

    private func append(level: DiagnosticLevel, category: DiagnosticCategory, message: String) {
        let line = "\(Self.timestamp()) [\(level.rawValue)] [\(category.rawValue)] \(message)\n"
        let url = logFileURL()
        do {
            try FileManager.default.createDirectory(
                at: diagnosticsDirectory(),
                withIntermediateDirectories: true
            )
            rotateIfNeeded(at: url, incomingBytes: line.utf8.count)

            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: url, options: .atomic)
            }
        } catch {
            // Logging must never affect app behavior.
        }
    }

    private func diagnosticsDirectory() -> URL {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private func rotateIfNeeded(at url: URL, incomingBytes: Int) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let currentSize = attrs[.size] as? UInt64,
              currentSize + UInt64(incomingBytes) > maxLogBytes,
              let data = try? Data(contentsOf: url)
        else { return }

        let keepBytes = Int(maxLogBytes / 2)
        let trimmed = data.suffix(keepBytes)
        try? trimmed.write(to: url, options: .atomic)
    }

    private nonisolated static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private nonisolated static var directoryName: String {
        isRunningTests ? testDirectoryName : productionDirectoryName
    }

    private nonisolated static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
