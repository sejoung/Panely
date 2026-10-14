import Foundation
import Translation

/// Whether Apple Translation can translate a language pair on this Mac.
nonisolated enum TranslationLanguageStatus: Equatable, Sendable {
    case installed
    /// Supported, but the language pack hasn't been downloaded yet.
    case needsDownload
    case unsupported
}

@available(macOS 26.0, *)
nonisolated enum TranslationAvailability {
    static func status(from source: TranslationLanguage, to target: TranslationLanguage) async -> TranslationLanguageStatus {
        guard source != target else { return .unsupported }
        switch await LanguageAvailability().status(from: source.localeLanguage, to: target.localeLanguage) {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }
}

/// Translates balloon text on-device with Apple Translation.
///
/// Uses `TranslationSession(installedSource:target:)` (macOS 26), which works
/// outside SwiftUI but can't prompt for a language download — callers check
/// `TranslationAvailability` first and send the user to Settings, where the
/// download runs through SwiftUI's `translationTask`.
///
/// Not `Sendable`: one translation job owns one translator.
@available(macOS 26.0, *)
nonisolated final class PageTranslator {
    private let session: TranslationSession

    init(from source: TranslationLanguage, to target: TranslationLanguage) {
        session = TranslationSession(installedSource: source.localeLanguage, target: target.localeLanguage)
    }

    /// One balloon. Apple Translation processes sentences one after another
    /// (~1 s each, however they're batched — measured), so balloons are
    /// translated singly and shown the moment each arrives.
    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }

    func cancel() {
        session.cancel()
    }
}
