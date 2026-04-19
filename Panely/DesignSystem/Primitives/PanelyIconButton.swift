import SwiftUI

struct PanelyIconButton: View {
    let systemImage: String
    var isActive: Bool = false
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
