import SwiftUI

struct FileNodeRow: View {
    let node: FileNode
    let isActive: Bool
    var badge: ReadingBadge? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: PanelySpacing.sm) {
                Image(systemName: node.iconName)
                    .foregroundStyle(isActive ? PanelyColor.accentPrimary : PanelyColor.textSecondary)
                    .frame(width: 16)
                Text(node.name)
                    .font(PanelyTypography.body)
                    .foregroundStyle(isActive ? PanelyColor.accentPrimary : PanelyColor.textPrimary)
                    .lineLimit(1)
                    // Volume numbers live at the end of the name, so tail
                    // truncation hides exactly the part that distinguishes
                    // "… Vol.03" from "… Vol.13". Middle truncation keeps both
                    // ends visible.
                    .truncationMode(.middle)
                if let ext = node.fileExtension {
                    Text(".\(ext)")
                        .font(PanelyTypography.caption)
                        .foregroundStyle(PanelyColor.textSecondary.opacity(0.6))
                }
                Spacer(minLength: 0)
                if let badge {
                    ReadingBadgeView(badge: badge)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
            // Full name on hover, for when even middle truncation isn't enough.
            .help(fullName)
        }
        .buttonStyle(.plain)
    }

    private var fullName: String {
        guard let ext = node.fileExtension else { return node.name }
        return "\(node.name).\(ext)"
    }
}
