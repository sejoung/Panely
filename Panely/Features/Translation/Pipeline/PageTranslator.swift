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
    /// `mode` matters: each model has its own language packs.
    static func status(
        from source: TranslationLanguage,
        to target: TranslationLanguage,
        mode: TranslationMode
    ) async -> TranslationLanguageStatus {
        guard source != target else { return .unsupported }
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: mode.effective.strategy)
        } else {
            availability = LanguageAvailability()
        }
        switch await availability.status(from: source.localeLanguage, to: target.localeLanguage) {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// For SwiftUI's `translationTask`, the one API that may download a
    /// language pack — the pack for `mode`'s model.
    static func configuration(
        from source: TranslationLanguage,
        to target: TranslationLanguage,
        mode: TranslationMode
    ) -> TranslationSession.Configuration {
        if #available(macOS 26.4, *) {
            return TranslationSession.Configuration(
                source: source.localeLanguage,
                target: target.localeLanguage,
                preferredStrategy: mode.effective.strategy
            )
        }
        return TranslationSession.Configuration(source: source.localeLanguage, target: target.localeLanguage)
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

    init(from source: TranslationLanguage, to target: TranslationLanguage, mode: TranslationMode) {
        if #available(macOS 26.4, *) {
            session = TranslationSession(
                installedSource: source.localeLanguage,
                target: target.localeLanguage,
                preferredStrategy: mode.effective.strategy
            )
        } else {
            session = TranslationSession(installedSource: source.localeLanguage, target: target.localeLanguage)
        }
    }

    /// One balloon. Apple Translation processes sentences one after another
    /// (batching, joining or parallel sessions take as long — measured), so
    /// balloons are translated singly and shown the moment each arrives.
    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }

    func cancel() {
        session.cancel()
    }
}
