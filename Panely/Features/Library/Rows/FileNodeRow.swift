import SwiftUI

struct FileNodeRow: View {
    let node: FileNode
    let isActive: Bool
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
                if let ext = node.fileExtension {
                    Text(".\(ext)")
                        .font(PanelyTypography.caption)
                        .foregroundStyle(PanelyColor.textSecondary.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
