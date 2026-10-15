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

    private nonisolated static let logFileName = "recent-log.txt"
    private nonisolated static let productionDirectoryName = "panely-diagnostics"
    private nonisolated static let testDirectoryName = "panely-diagnostics-tests"
    /// Resolved once: every appended line used to look up the caches
    /// directory and re-check the test environment.
    private nonisolated let directoryURL: URL
    private nonisolated let fileURL: URL

    /// Kept open between appends (one `open`/`close` per line was most of a
    /// log call's cost) and reopened after rotation, `clear()`, or the file
    /// vanishing underneath it. `fileSize` mirrors the file's length so
    /// rotation needs no `stat` per line.
    private var handle: FileHandle?
    private var fileSize: UInt64 = 0
    /// Appends since the open file was last confirmed to still exist (the
    /// caches directory can be emptied from outside the app).
    private var appendsSinceExistenceCheck = 0
    private nonisolated static let existenceCheckInterval = 64

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
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        self.directoryURL = caches.appendingPathComponent(
            directoryName ?? Self.directoryName,
            isDirectory: true
        )
        self.fileURL = directoryURL.appendingPathComponent(Self.logFileName)
        let (stream, continuation) = AsyncStream.makeStream(of: Entry.self)
        self.stream = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
        try? handle?.close()
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
        fileURL
    }

    func diagnosticsDirectoryURL() -> URL {
        directoryURL
    }

    func ensureDiagnosticsDirectory() -> URL {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
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
        closeHandle()
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
        let line = Data("\(entry.timestamp) [\(entry.level.wireName)] [\(entry.category.rawValue)] \(entry.message)\n".utf8)
        do {
            if handle != nil {
                appendsSinceExistenceCheck += 1
                if appendsSinceExistenceCheck >= Self.existenceCheckInterval {
                    appendsSinceExistenceCheck = 0
                    if !FileManager.default.fileExists(atPath: fileURL.path) { closeHandle() }
                }
            }
            var handle = try openHandle()
            if fileSize + UInt64(line.count) > DiagnosticLogPolicy.maxLogBytes {
                rotate()
                handle = try openHandle()
            }
            try handle.write(contentsOf: line)
            fileSize += UInt64(line.count)
        } catch {
            // Logging must never affect app behavior. Reopen next time.
            closeHandle()
        }
    }

    /// The open append handle, opening (and creating) the file on first use.
    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }
        let opened = try FileHandle(forWritingTo: fileURL)
        fileSize = try opened.seekToEnd()
        handle = opened
        appendsSinceExistenceCheck = 0
        return opened
    }

    /// Keep the newest `trimToBytes` of the log. The trimmed copy replaces
    /// the file atomically, so the old handle is closed and the next append
    /// opens the new file.
    private func rotate() {
        closeHandle()
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let keepBytes = Int(DiagnosticLogPolicy.trimToBytes)
        try? data.suffix(keepBytes).write(to: fileURL, options: .atomic)
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
        fileSize = 0
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

    /// Fixed for the life of the process, so evaluated once.
    private nonisolated static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()
}
