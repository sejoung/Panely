import SwiftUI

struct LibrarySidebar: View {
    let rootURL: URL?
    let activeURL: URL?
    let onSelect: (URL) -> Void
    let onOpen: () -> Void

    @State private var nodes: [FileNode] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .overlay(PanelyColor.borderSubtle)

            if rootURL == nil {
                emptyState
            } else {
                tree
            }
        }
        .frame(width: 240)
        .background(PanelyColor.bgSecondary)
    }

    private var header: some View {
        HStack(spacing: PanelySpacing.sm) {
            Image(systemName: "books.vertical")
                .foregroundStyle(PanelyColor.textSecondary)
            Text(rootURL?.lastPathComponent ?? "Library")
                .font(PanelyTypography.body)
                .foregroundStyle(PanelyColor.textPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, PanelySpacing.md)
        .padding(.vertical, PanelySpacing.sm)
    }

    private var tree: some View {
        List(nodes, children: \.children) { node in
            FileNodeRow(
                node: node,
                isActive: activeURL?.standardizedFileURL == node.url.standardizedFileURL,
                onTap: { onSelect(node.url) }
            )
            .listRowBackground(Color.clear)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .task(id: rootURL) {
            guard let rootURL else {
                nodes = []
                return
            }
            nodes = await FileNode.loadTree(from: rootURL, maxDepth: 3)
        }
    }

    private var emptyState: some View {
        VStack(spacing: PanelySpacing.sm) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(PanelyColor.textSecondary)
            Text("No library opened")
                .font(PanelyTypography.body)
                .foregroundStyle(PanelyColor.textSecondary)
            Button(action: onOpen) {
                Text("Open Folder…")
                    .font(PanelyTypography.caption)
                    .foregroundStyle(PanelyColor.accentPrimary)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(PanelySpacing.md)
    }
}

private struct FileNodeRow: View {
    let node: FileNode
    let isActive: Bool
    let onTap: () -> Void

    @State private var isHovering = false

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
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    LibrarySidebar(
        rootURL: URL(fileURLWithPath: "/Users/demo/Comics/OnePiece"),
        activeURL: nil,
        onSelect: { _ in },
        onOpen: {}
    )
    .frame(height: 480)
    .background(PanelyColor.bgPrimary)
}
