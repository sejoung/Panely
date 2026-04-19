import SwiftUI

struct LoadingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            HStack(spacing: PanelySpacing.md) {
                ProgressView()
                    .controlSize(.regular)
                Text(message.isEmpty ? "Loading…" : message)
                    .font(PanelyTypography.body)
                    .foregroundStyle(PanelyColor.textPrimary)
            }
            .padding(.horizontal, PanelySpacing.lg)
            .padding(.vertical, PanelySpacing.md)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(PanelyColor.borderSubtle, lineWidth: 1)
                    )
            )
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

#Preview {
    LoadingOverlay(message: "Extracting archive…")
        .frame(width: 640, height: 480)
        .background(PanelyColor.bgPrimary)
}
