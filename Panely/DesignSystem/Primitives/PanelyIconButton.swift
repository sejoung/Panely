import SwiftUI

struct PanelyIconButton: View {
    let systemImage: String
    var isActive: Bool = false
    /// VoiceOver label. Falls back to the SF Symbol name when unset so the
    /// button still announces something, but callers should pass a real
    /// label — `.help()` is sighted-user only.
    var accessibilityTitle: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 32, height: 32)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(PanelyMotion.uiReveal, value: isHovering)
        .animation(PanelyMotion.uiReveal, value: isActive)
        .accessibilityLabel(accessibilityTitle ?? systemImage)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var background: Color {
        if isActive { return PanelyColor.accentPrimary }
        if isHovering { return PanelyColor.bgTertiary }
        return .clear
    }

    private var foreground: Color {
        isActive ? .white : PanelyColor.textPrimary
    }
}

#Preview {
    HStack(spacing: PanelySpacing.md) {
        PanelyIconButton(systemImage: "folder") {}
        PanelyIconButton(systemImage: "chevron.left") {}
        PanelyIconButton(systemImage: "chevron.right") {}
        PanelyIconButton(systemImage: "sidebar.left", isActive: true) {}
    }
    .padding(PanelySpacing.lg)
    .background(PanelyColor.bgSecondary)
}
