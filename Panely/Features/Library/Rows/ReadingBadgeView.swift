import SwiftUI

/// Small trailing indicator for a book's reading state in the sidebar:
/// a filled check for finished, a progress ring for in-progress (or a
/// half ring when the total is unknown).
struct ReadingBadgeView: View {
    let badge: ReadingBadge

    var body: some View {
        switch badge {
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PanelyColor.textSecondary)
                .help("Finished")
        case .inProgress(let fraction):
            ReadingProgressRing(fraction: fraction)
                .help(fraction.map { "\(Int(($0 * 100).rounded()))% read" } ?? "In progress")
        }
    }
}

private struct ReadingProgressRing: View {
    /// `nil` = unknown total → show a fixed half ring as a generic "reading" cue.
    let fraction: Double?

    private var trimEnd: CGFloat {
        guard let fraction else { return 0.5 }
        return CGFloat(min(1, max(0.05, fraction)))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(PanelyColor.textSecondary.opacity(0.25), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: trimEnd)
                .stroke(PanelyColor.accentPrimary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
    }
}
