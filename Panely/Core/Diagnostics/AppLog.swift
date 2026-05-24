import Foundation
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
    case debug = "DEBUG"
    case info = "INFO"
    case error = "ERROR"
}

nonisolated enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.sejoung.Panely"

    private static let app = Logger(subsystem: subsystem, category: DiagnosticCategory.app.rawValue)
    private static let reader = Logger(subsystem: subsystem, category: DiagnosticCategory.reader.rawValue)
    private static let load = Logger(subsystem: subsystem, category: DiagnosticCategory.load.rawValue)
    private static let cache = Logger(subsystem: subsystem, category: DiagnosticCategory.cache.rawValue)
    private static let library = Logger(subsystem: subsystem, category: DiagnosticCategory.library.rawValue)
    private static let persistence = Logger(subsystem: subsystem, category: DiagnosticCategory.persistence.rawValue)
    private static let image = Logger(subsystem: subsystem, category: DiagnosticCategory.image.rawValue)
    private static let diagnostics = Logger(subsystem: subsystem, category: DiagnosticCategory.diagnostics.rawValue)

    static func debug(_ category: DiagnosticCategory, _ message: String) {
        logger(for: category).debug("\(message, privacy: .public)")
        DiagnosticLogStore.record(level: .debug, category: category, message: message)
    }

    static func info(_ category: DiagnosticCategory, _ message: String) {
        logger(for: category).info("\(message, privacy: .public)")
        DiagnosticLogStore.record(level: .info, category: category, message: message)
    }

    static func error(_ category: DiagnosticCategory, _ message: String) {
        logger(for: category).error("\(message, privacy: .public)")
        DiagnosticLogStore.record(level: .error, category: category, message: message)
    }

    private static func logger(for category: DiagnosticCategory) -> Logger {
        switch category {
        case .app:
            app
        case .reader:
            reader
        case .load:
            load
        case .cache:
            cache
        case .library:
            library
        case .persistence:
            persistence
        case .image:
            image
        case .diagnostics:
            diagnostics
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
}
