import Foundation
import Logging
import OSLog

nonisolated enum DiagnosticCategory: String, Sendable {
    case app
    case reader
    case load
    case cache
    case library
    case persistence
    case image
    case diagnostics
}

nonisolated enum DiagnosticLevel: String, Sendable {
    case trace = "TRACE"
    case debug = "DEBUG"
    case info = "INFO"
    case notice = "NOTICE"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"
}

nonisolated enum DiagnosticLogLevel: String, CaseIterable, Identifiable, Sendable {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trace:
            return "Trace"
        case .debug:
            return "Debug"
        case .info:
            return "Info"
        case .notice:
            return "Notice"
        case .warning:
            return "Warning"
        case .error:
            return "Error"
        case .critical:
            return "Critical"
        }
    }

    var loggerLevel: Logging.Logger.Level {
        switch self {
        case .trace:
            return .trace
        case .debug:
            return .debug
        case .info:
            return .info
        case .notice:
            return .notice
        case .warning:
            return .warning
        case .error:
            return .error
        case .critical:
            return .critical
        }
    }
}

nonisolated enum DiagnosticLogConfiguration {
    static let logLevelKey = "panely.diagnostics.logLevel"

    static var currentLogLevel: DiagnosticLogLevel {
        let rawValue = UserDefaults.standard.string(forKey: logLevelKey)
        return rawValue.flatMap(DiagnosticLogLevel.init(rawValue:)) ?? .info
    }

    static func setCurrentLogLevel(_ level: DiagnosticLogLevel) {
        UserDefaults.standard.set(level.rawValue, forKey: logLevelKey)
    }
}

nonisolated enum DiagnosticSession {
    static let id = UUID().uuidString
    static let launchedAt = ISO8601DateFormatter().string(from: Date())
}

nonisolated enum AppLog {
    typealias Metadata = Logging.Logger.Metadata

    static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.sejoung.Panely"

    static func trace(
        _ category: DiagnosticCategory,
        _ message: @autoclosure () -> String,
        metadata: Metadata? = nil,
        source: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            level: .trace,
            category,
            message(),
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }

    static func debug(
        _ category: DiagnosticCategory,
        _ message: @autoclosure () -> String,
        metadata: Metadata? = nil,
        source: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            level: .debug,
            category,
            message(),
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }

    static func info(
        _ category: DiagnosticCategory,
        _ message: @autoclosure () -> String,
        metadata: Metadata? = nil,
        source: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            level: .info,
            category,
            message(),
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }

    static func warning(
        _ category: DiagnosticCategory,
        _ message: @autoclosure () -> String,
        metadata: Metadata? = nil,
        source: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            level: .warning,
            category,
            message(),
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }

    static func notice(
        _ category: DiagnosticCategory,
        _ message: @autoclosure () -> String,
        metadata: Metadata? = nil,
        source: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            level: .notice,
            category,
            message(),
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }

    static func error(
        _ category: DiagnosticCategory,
        _ message: @autoclosure () -> String,
        metadata: Metadata? = nil,
        source: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            level: .error,
            category,
            message(),
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }

    static func critical(
        _ category: DiagnosticCategory,
        _ message: @autoclosure () -> String,
        metadata: Metadata? = nil,
        source: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            level: .critical,
            category,
            message(),
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }

    private static func log(
        level: Logging.Logger.Level,
        _ category: DiagnosticCategory,
        _ message: String,
        metadata: Metadata?,
        source: String?,
        file: String,
        function: String,
        line: UInt
    ) {
        logger(for: category).log(
            level: level,
            "\(message)",
            metadata: metadata,
            source: source ?? category.rawValue,
            file: file,
            function: function,
            line: line
        )
    }

    private static func logger(for category: DiagnosticCategory) -> Logging.Logger {
        Logging.Logger(label: "\(subsystem).\(category.rawValue)") { label, metadataProvider in
            PanelyLogHandler(
                label: label,
                subsystem: subsystem,
                category: category,
                metadataProvider: metadataProvider
            )
        }
    }
}

nonisolated enum DiagnosticRedactor {
    static func describe(_ url: URL?) -> String {
        guard let url else { return "nil" }
        let name = url.lastPathComponent.isEmpty ? "<root>" : url.lastPathComponent
        let ext = url.pathExtension.isEmpty ? "none" : url.pathExtension.lowercased()
        let type = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
            ? "directory"
            : "file"
        return "name=\(name) ext=\(ext) type=\(type)"
    }

    static func describe(_ urls: [URL], limit: Int = 5) -> String {
        guard !urls.isEmpty else { return "none" }
        let prefix = urls.prefix(limit).map { describe($0) }.joined(separator: ", ")
        if urls.count > limit {
            return "\(prefix), +\(urls.count - limit) more"
        }
        return prefix
    }

    static func redactKnownPaths(in text: String, urls: [URL?]) -> String {
        guard text.isEmpty == false else { return text }

        var paths = Set<String>()
        for url in urls.compactMap({ $0 }) {
            let standardized = url.standardizedFileURL
            paths.insert(standardized.path)
            paths.insert(standardized.deletingLastPathComponent().path)
        }

        return paths
            .filter { !$0.isEmpty && $0 != "/" }
            .sorted { $0.count > $1.count }
            .reduce(text) { redacted, path in
                redacted.replacingOccurrences(of: path, with: "<redacted-path>")
            }
    }
}

private nonisolated struct PanelyLogHandler: LogHandler {
    let label: String
    let subsystem: String
    let category: DiagnosticCategory
    private let osLog: OSLog

    var metadata: Logging.Logger.Metadata = [:]
    var metadataProvider: Logging.Logger.MetadataProvider?
    var logLevel: Logging.Logger.Level

    init(
        label: String,
        subsystem: String,
        category: DiagnosticCategory,
        metadataProvider: Logging.Logger.MetadataProvider?
    ) {
        self.label = label
        self.subsystem = subsystem
        self.category = category
        self.metadataProvider = metadataProvider
        self.osLog = OSLog(subsystem: subsystem, category: category.rawValue)
        self.logLevel = DiagnosticLogConfiguration.currentLogLevel.loggerLevel
    }

    subscript(metadataKey metadataKey: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[metadataKey] }
        set { metadata[metadataKey] = newValue }
    }

    func log(event: Logging.LogEvent) {
        guard event.level >= logLevel else { return }

        var mergedMetadata = metadata
        let providedMetadata = metadataProvider?.get() ?? [:]
        if providedMetadata.isEmpty == false {
            mergedMetadata.merge(providedMetadata) { _, providedValue in providedValue }
        }
        if let callsiteMetadata = event.metadata, callsiteMetadata.isEmpty == false {
            mergedMetadata.merge(callsiteMetadata) { _, callsiteValue in callsiteValue }
        }
        if let error = event.error {
            mergedMetadata["error.message"] = "\(error)"
            mergedMetadata["error.type"] = "\(String(reflecting: type(of: error)))"
        }

        let renderedMessage = Self.render(message: "\(event.message)", metadata: mergedMetadata)
        writeToOSLog(level: event.level, message: renderedMessage)
        DiagnosticLogStore.record(
            level: DiagnosticLevel(event.level),
            category: category,
            message: renderedMessage
        )
    }

    private func writeToOSLog(level: Logging.Logger.Level, message: String) {
        let type: OSLogType
        switch level {
        case .trace, .debug:
            type = .debug
        case .info, .notice:
            type = .info
        case .warning:
            type = .default
        case .error:
            type = .error
        case .critical:
            type = .fault
        }
        os_log("%{public}@", log: osLog, type: type, message)
    }

    private static func render(message: String, metadata: Logging.Logger.Metadata) -> String {
        let renderedMetadata = metadata
            .sorted { $0.key < $1.key }
            .map { key, value in "\(key)=\(sanitize("\(value)"))" }
            .joined(separator: " ")
        let cleanMessage = sanitize(message)
        guard renderedMetadata.isEmpty == false else { return cleanMessage }
        return "\(cleanMessage) \(renderedMetadata)"
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

private extension DiagnosticLevel {
    nonisolated init(_ level: Logging.Logger.Level) {
        switch level {
        case .trace:
            self = .trace
        case .debug:
            self = .debug
        case .info:
            self = .info
        case .notice:
            self = .notice
        case .warning:
            self = .warning
        case .error:
            self = .error
        case .critical:
            self = .critical
        }
    }
}
