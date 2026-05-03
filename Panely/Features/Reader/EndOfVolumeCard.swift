import SwiftUI

/// Surfaced at the bottom of the viewer when the user reaches the last
/// page/spread of the current volume and a next sibling is available.
/// Doesn't auto-advance — the user must press "Next volume" so an
/// accidental key/scroll doesn't hop books.
struct EndOfVolumeCard: View {
    let nextVolumeName: String
    var onNext: () -> Void = {}
    var onRestart: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: PanelySpacing.sm) {
            HStack(spacing: PanelySpacing.sm) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PanelyColor.textSecondary)
                Text("Up next")
                    .font(PanelyTypography.caption)
                    .foregroundStyle(PanelyColor.textSecondary)
            }

            Text(nextVolumeName)
                .font(PanelyTypography.body)
                .foregroundStyle(PanelyColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: PanelySpacing.sm) {
                Button(action: onNext) {
                    HStack(spacing: PanelySpacing.xs) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Next volume")
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

                Button(action: onRestart) {
                    HStack(spacing: PanelySpacing.xs) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Restart")
                    }
                    .font(PanelyTypography.body)
                    .foregroundStyle(PanelyColor.textPrimary)
                    .padding(.horizontal, PanelySpacing.md)
                    .padding(.vertical, PanelySpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(PanelyColor.bgTertiary)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(PanelySpacing.lg)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(PanelyColor.borderSubtle, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .padding(.bottom, PanelySpacing.xl)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

#Preview {
    EndOfVolumeCard(nextVolumeName: "Vol 02 - The Long Trail")
        .frame(width: 800, height: 600)
        .background(PanelyColor.bgPrimary)
}
