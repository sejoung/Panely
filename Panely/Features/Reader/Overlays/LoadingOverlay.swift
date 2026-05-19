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
        // Block click/scroll-through while loading. ReaderViewModel has an
        // epoch guard that swallows redundant loads, but accidental clicks
        // landing on toolbar items behind the overlay still toggled visible
        // chrome state (sidebar pin, layout) mid-load. Hit-testing on keeps
        // the dim layer authoritative; explicit empty gesture is needed so
        // SwiftUI's pass-through doesn't fall through to deeper views.
        .contentShape(Rectangle())
        .onTapGesture { /* swallow */ }
        .transition(.opacity)
    }
}

#Preview {
    LoadingOverlay(message: "Extracting archive…")
        .frame(width: 640, height: 480)
        .background(PanelyColor.bgPrimary)
}
