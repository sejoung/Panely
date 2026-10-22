import Foundation
import Testing

/// Which test tiers this run includes, beyond the default fast tier.
///
/// The default `xcodebuild test` (and CI) runs only the fast tier. The other
/// tiers are opt-in through environment variables, which xcodebuild hands the
/// test process when they're passed with a `TEST_RUNNER_` prefix — the
/// scripts do that:
///
/// - `scripts/test.sh` — fast tier only.
/// - `scripts/test-slow.sh` — adds the slow tier: real FSEvents streams (each
///   waits out the stream's 1 s latency), real Vision OCR, and the randomized
///   sequences over every seed instead of a few.
/// - `scripts/test-visual.sh` — the screenshot comparisons
///   (`VisualRegressionTests`) only.
/// - `scripts/benchmark-translation.sh` — `TranslationBenchmarkTests`, gated
///   on its own `PANELY_BENCHMARK=1`.
/// - `scripts/test-model.sh` — `GemmaTranslatorIntegrationTests`, the real
///   translation model, gated on `PANELY_MODEL_TESTS=1`.
enum TestTier {
    /// `PANELY_SLOW_TESTS=1`
    static var slow: Bool { flag("PANELY_SLOW_TESTS") }

    /// `PANELY_VISUAL_TESTS=1`
    static var visual: Bool { flag("PANELY_VISUAL_TESTS") }

    /// `PANELY_MODEL_TESTS=1`
    static var model: Bool { flag("PANELY_MODEL_TESTS") }

    /// Seeds for a randomized test: a couple in the fast tier, all of them in
    /// the slow tier.
    static func seeds(_ all: [UInt64], fast count: Int = 2) -> [UInt64] {
        slow ? all : Array(all.prefix(count))
    }

    static let slowReason: Comment = "slow tier: run scripts/test-slow.sh"
    static let visualReason: Comment = "visual tier: run scripts/test-visual.sh"
    static let modelReason: Comment = "model tier: run scripts/test-model.sh with the model downloaded"

    private static func flag(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment[name] == "1"
    }
}
