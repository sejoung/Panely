import Foundation
import Translation

/// Which of Apple Translation's models translates the balloons.
///
/// Measured on an M1 Pro over a Korean volume: the low-latency model takes
/// ~0.03 s a balloon, the high-fidelity one ~0.6 s — a volume in about a
/// minute instead of about twenty. High fidelity reads idioms better
/// ("수학도 깡통" → "bad at math" rather than "a math can"); for following
/// the story, the speed matters more. Each model has its own language packs.
nonisolated enum TranslationMode: String, CaseIterable, Codable, Sendable {
    case fast
    case accurate

    /// The low-latency model needs macOS 26.4.
    static var isFastAvailable: Bool {
        if #available(macOS 26.4, *) { return true }
        return false
    }

    /// What actually runs on this Mac: before 26.4 every job is accurate.
    var effective: TranslationMode {
        self == .fast && Self.isFastAvailable ? .fast : .accurate
    }

    @available(macOS 26.4, *)
    var strategy: TranslationSession.Strategy {
        self == .fast ? .lowLatency : .highFidelity
    }
}
