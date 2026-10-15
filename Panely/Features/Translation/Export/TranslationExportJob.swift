import Foundation
import Observation

/// What to do with pages that aren't translated yet when an export starts.
nonisolated enum UntranslatedPagesPolicy: String, Codable, CaseIterable, Sendable {
    /// Translate the rest first (through the usual queue), then export.
    case translateFirst
    /// Export now; untranslated pages go in as they are.
    case exportAsIs
}

/// The choices in the export sheet; remembered for next time.
nonisolated struct TranslationExportOptions: Codable, Equatable, Sendable {
    var target: TranslationLanguage
    var format: TranslationExportFormat = .cbz
    var untranslated: UntranslatedPagesPolicy = .translateFirst
}

/// What the export sheet is about: one book, or the volumes of a series.
struct TranslationExportRequest: Identifiable {
    let id = UUID()
    /// Volumes in reading order.
    let books: [URL]
    /// The book's or the series' name, for the sheet's title.
    let title: String
    let isSeries: Bool
    /// The language the series is shown in — the sheet's starting choice.
    let suggestedTarget: TranslationLanguage
}

/// One book being exported: translated first if needed, then rendered and
/// written. Lives in `TranslationExportManager` until it's finished (then it
/// becomes a `TranslationExportRecord`) or dismissed.
@Observable
@MainActor
final class TranslationExportJob: Identifiable {
    enum Stage: Equatable {
        /// Reading the book's pages and cached translations.
        case preparing
        /// Waiting for the rest of the book to be translated (`translation`).
        case translating
        /// Translated; waiting for the export ahead of it.
        case waiting
        case exporting(done: Int, total: Int)
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let bookURL: URL
    let title: String
    let options: TranslationExportOptions
    private(set) var stage: Stage = .preparing
    /// The translation job this export waits on while `.translating`.
    private(set) var translation: TranslationController?
    @ObservationIgnored var task: Task<Void, Never>?

    init(bookURL: URL, title: String, options: TranslationExportOptions) {
        self.bookURL = bookURL
        self.title = title
        self.options = options
    }

    var isActive: Bool {
        switch stage {
        case .preparing, .translating, .waiting, .exporting: true
        case .finished, .failed, .cancelled: false
        }
    }

    func setStage(_ stage: Stage) {
        // A cancelled job stays cancelled whatever its task reports on the way out.
        guard self.stage != .cancelled else { return }
        self.stage = stage
        if stage != .translating { translation = nil }
    }

    func waitOn(_ controller: TranslationController) {
        translation = controller
        setStage(.translating)
    }
}

/// A finished export, kept across launches for the jobs window.
nonisolated struct TranslationExportRecord: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let title: String
    let target: TranslationLanguage
    let format: TranslationExportFormat
    /// Where it was written.
    let path: String
    let pageCount: Int
    let bytes: Int64
    let date: Date

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: format == .folder)
    }
}

/// Why an export stopped.
nonisolated enum TranslationExportError: LocalizedError, Equatable {
    case unreadableBook
    case noDestination
    case translationStopped(String)
    case nothingTranslated

    var errorDescription: String? {
        switch self {
        case .unreadableBook:
            String(localized: "Couldn't read this book's pages. Archives inside archives can only be exported while open.", bundle: .localized)
        case .noDestination:
            String(localized: "Choose a folder to save to.", bundle: .localized)
        case let .translationStopped(reason):
            reason
        case .nothingTranslated:
            String(localized: "Nothing in this book is translated into this language yet.", bundle: .localized)
        }
    }
}
