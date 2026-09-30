import Foundation

/// The interface language the user picked in Settings → General.
///
/// Panely follows the system language by default, but someone on a Korean
/// system may still want an English UI (or the other way round). The choice
/// is applied live by `AppLocalization`.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    /// Follow the Mac's primary language — English when Panely doesn't
    /// support it (see `AppLocalization.resolve`).
    case system
    case english = "en"
    case korean = "ko"

    var id: String { rawValue }
}
