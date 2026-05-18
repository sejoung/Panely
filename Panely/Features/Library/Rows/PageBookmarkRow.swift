import SwiftUI

struct PageBookmarkRow: View {
    let bookmark: PageBookmark
    let isCurrent: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: PanelySpacing.sm) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(isCurrent ? PanelyColor.accentPrimary : PanelyColor.textSecondary)
                    .frame(width: 16)
                Text("Page \(bookmark.pageIndex + 1)")
                    .font(PanelyTypography.body)
                    .foregroundStyle(isCurrent ? PanelyColor.accentPrimary : PanelyColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove Bookmark", role: .destructive, action: onRemove)
        }
    }
}
