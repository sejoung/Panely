import SwiftUI

/// Top-anchored counterpart to `EndOfVolumeCard`. Surfaced when the user
/// signals intent to go back further than page 1 — see `goBackward()` for
/// the trigger logic.
struct PreviousVolumeCard: View {
    let previousVolumeName: String
    var onPrevious: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: PanelySpacing.sm) {
            HStack(spacing: PanelySpacing.sm) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PanelyColor.textPrimary.opacity(0.85))
                Text("Previous")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(PanelyColor.textPrimary.opacity(0.85))
            }

            Text(previousVolumeName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PanelyColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button(action: onPrevious) {
                HStack(spacing: PanelySpacing.xs) {
                    Image(systemName: "play.fill")
                        .rotationEffect(.degrees(180))
                        .font(.system(size: 11, weight: .semibold))
                    Text("Previous volume")
                }
                .font(PanelyTypography.body)
                .foregroundStyle(.white)
                .padding(.horizontal, PanelySpacing.md)
                .padding(.vertical, PanelySpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(PanelyColor.accentPrimary)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(PanelySpacing.lg)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(PanelyColor.bgSecondary.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(PanelyColor.borderSubtle, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .padding(.top, PanelySpacing.xl)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

#Preview {
    PreviousVolumeCard(previousVolumeName: "Vol 01 - The Beginning")
        .frame(width: 800, height: 600)
        .background(PanelyColor.bgPrimary)
}
