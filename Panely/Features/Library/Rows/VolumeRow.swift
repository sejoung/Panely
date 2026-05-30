import SwiftUI

struct VolumeRow: View {
    let url: URL
    let isActive: Bool
    let badge: ReadingBadge?
    let onTap: () -> Void

    private let iconName: String
    private let displayName: String

    init(url: URL, isActive: Bool, badge: ReadingBadge? = nil, onTap: @escaping () -> Void) {
        self.url = url
        self.isActive = isActive
        self.badge = badge
        self.onTap = onTap
        // Resolve `isDirectory` once at init instead of on every body
        // evaluation (the previous shape called the resourceValues stat
        // twice per render — once for icon, once for name).
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        self.iconName = isDir ? "folder" : "doc.zipper"
        self.displayName = isDir ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: PanelySpacing.sm) {
                Image(systemName: iconName)
                    .foregroundStyle(isActive ? PanelyColor.accentPrimary : PanelyColor.textSecondary)
                    .frame(width: 16)
                Text(displayName)
                    .font(PanelyTypography.body)
                    .foregroundStyle(isActive ? PanelyColor.accentPrimary : PanelyColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge {
                    ReadingBadgeView(badge: badge)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
