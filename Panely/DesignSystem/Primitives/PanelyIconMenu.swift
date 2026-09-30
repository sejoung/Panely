import SwiftUI

/// A pull-down menu that looks and hovers like `PanelyIconButton`, for
/// toolbar controls whose job is "pick one of these" rather than a single
/// action.
struct PanelyIconMenu<Content: View>: View {
    let systemImage: String
    var accessibilityTitle: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PanelyColor.textPrimary)
                .frame(width: 32, height: 32)
                .background(isHovering ? PanelyColor.bgTertiary : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(PanelyMotion.uiReveal, value: isHovering)
        .accessibilityLabel(Text(accessibilityTitle))
    }
}

#Preview {
    PanelyIconMenu(systemImage: "list.bullet.rectangle", accessibilityTitle: "Bookmark List") {
        Button("Page 3") {}
        Button("Page 17") {}
    }
    .padding(PanelySpacing.lg)
    .background(PanelyColor.bgSecondary)
}
