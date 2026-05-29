import Foundation

nonisolated enum DiagnosticLogPolicy {
    static let maxLogBytes: UInt64 = 768 * 1024
    static let reportLogBytes: UInt64 = 256 * 1024

    static var trimToBytes: UInt64 {
        maxLogBytes / 2
    }
}

actor DiagnosticLogStore {
    /// The app-wide store. Its FIFO consumer is started here so log lines
    /// written through the `nonisolated static record` fast path land in call
    /// order (see `continuation`).
    static let shared: DiagnosticLogStore = {
        let store = DiagnosticLogStore()
        Task { await store.beginConsuming() }
        return store
    }()

    struct Entry: Sendable {
        let timestamp: String
        let level: DiagnosticLogLevel
        let category: DiagnosticCategory
        let message: String
    }

    private let logFileName = "recent-log.txt"
    private let directoryNameOverride: String?
    private nonisolated static let productionDirectoryName = "panely-diagnostics"
    private nonisolated static let testDirectoryName = "panely-diagnostics-tests"

    // FIFO pipeline for the fire-and-forget static `record` path. Previously
    // each call spawned its own `Task.detached`, and detached tasks have no
    // ordering guarantee — so sequential log calls could be appended out of
    // order, producing non-monotonic timestamps and shuffled events. Yielding
    // into an `AsyncStream` preserves call order; a single consumer drains it
    // and appends serially. The timestamp is captured at call time so it
    // reflects when the event happened, not when it was flushed.
    private nonisolated let continuation: AsyncStream<Entry>.Continuation
    private let stream: AsyncStream<Entry>

    init(directoryName: String? = nil) {
        self.directoryNameOverride = directoryName
        let (stream, continuation) = AsyncStream.makeStream(of: Entry.self)
        self.stream = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    /// Drains the FIFO stream. Started only for `shared` (which lives for the
    /// process lifetime); ad-hoc instances used in tests append directly via
    /// the instance `record` method and never start a consumer.
    private func beginConsuming() async {
        for await entry in stream {
            append(entry)
        }
    }

    nonisolated static func record(
        level: DiagnosticLogLevel,
        category: DiagnosticCategory,
        message: String
    ) {
        let entry = Entry(
            timestamp: timestamp(),
            level: level,
            category: category,
            message: message
        )
        shared.continuation.yield(entry)
    }

    func record(level: DiagnosticLogLevel, category: DiagnosticCategory, message: String) {
        append(Entry(timestamp: Self.timestamp(), level: level, category: category, message: message))
    }

    func logFileURL() -> URL {
        diagnosticsDirectory().appendingPathComponent(logFileName)
    }

    func diagnosticsDirectoryURL() -> URL {
        diagnosticsDirectory()
    }

    func ensureDiagnosticsDirectory() -> URL {
        let url = diagnosticsDirectory()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func logSizeBytes() -> UInt64 {
        let url = logFileURL()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64
        else { return 0 }
        return size
    }

    func recentLogText(maxBytes: Int? = nil) -> String {
        let url = logFileURL()
        let maxBytes = maxBytes ?? Int(DiagnosticLogPolicy.reportLogBytes)
        guard let data = try? Data(contentsOf: url) else { return "" }
        let slice: Data
        if data.count > maxBytes {
            slice = data.suffix(maxBytes)
        } else {
            slice = data
        }
        return String(decoding: slice, as: UTF8.self)
    }

    func recentEvents(categories: Set<DiagnosticCategory>, maxLines: Int = 100) -> String {
        let wanted = Set(categories.map { $0.rawValue })
        let lines = recentLogText().split(separator: "\n", omittingEmptySubsequences: false)
        let filtered = lines.filter { line in
            // Match the category positionally (the 2nd bracketed token) rather
            // than by substring, so message text like "[load]" can't smuggle a
            // line into the wrong category's report.
            guard let category = Self.parseCategory(from: line) else { return false }
            return wanted.contains(category)
        }
        return filtered.suffix(maxLines).joined(separator: "\n")
    }

    /// Extracts `CATEGORY` from a `"<timestamp> [LEVEL] [CATEGORY] message"`
    /// line, or nil if the line doesn't match the structured prefix.
    private static func parseCategory(from line: Substring) -> String? {
        let groups = line.split(separator: "[", maxSplits: 2, omittingEmptySubsequences: false)
        guard groups.count >= 3, let close = groups[2].firstIndex(of: "]") else { return nil }
        return String(groups[2][..<close])
    }

    /// Removes the log file. Returns `true` on success (including the
    /// already-absent case) so callers can report the real outcome instead of
    /// assuming success.
    @discardableResult
    func clear() -> Bool {
        let url = logFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private func append(_ entry: Entry) {
        let line = "\(entry.timestamp) [\(entry.level.wireName)] [\(entry.category.rawValue)] \(entry.message)\n"
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
        return caches.appendingPathComponent(directoryNameOverride ?? Self.directoryName, isDirectory: true)
    }

    private func rotateIfNeeded(at url: URL, incomingBytes: Int) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let currentSize = attrs[.size] as? UInt64,
              currentSize + UInt64(incomingBytes) > DiagnosticLogPolicy.maxLogBytes,
              let data = try? Data(contentsOf: url)
        else { return }

        let keepBytes = Int(DiagnosticLogPolicy.trimToBytes)
        let trimmed = data.suffix(keepBytes)
        try? trimmed.write(to: url, options: .atomic)
    }

    // ISO8601DateFormatter is comparatively expensive to allocate; reuse one.
    // It is documented thread-safe for formatting, which matters because
    // `timestamp()` is called from the nonisolated static `record` fast path.
    // `nonisolated(unsafe)`: ISO8601DateFormatter isn't `Sendable`, but
    // `.string(from:)` is documented thread-safe, which is all we use it for.
    private nonisolated(unsafe) static let isoFormatter = ISO8601DateFormatter()

    private nonisolated static func timestamp() -> String {
        isoFormatter.string(from: Date())
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
