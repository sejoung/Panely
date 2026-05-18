import SwiftUI

struct FavoriteRow: View {
    let favorite: FavoriteBook
    let isActive: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: PanelySpacing.sm) {
                Image(systemName: favorite.iconName)
                    .foregroundStyle(isActive ? PanelyColor.accentPrimary : PanelyColor.textSecondary)
                    .frame(width: 16)
                Text(favorite.title)
                    .font(PanelyTypography.body)
                    .foregroundStyle(isActive ? PanelyColor.accentPrimary : PanelyColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove from Favorites", role: .destructive, action: onRemove)
        }
    }
}
