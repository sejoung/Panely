import SwiftUI

struct LibrarySidebar: View {
    let rootURL: URL?
    let activeURL: URL?
    let refreshToken: UUID
    let onSelect: (URL) -> Void
    let onOpen: () -> Void
    let onHide: () -> Void
    let onRequestFolderAccess: () -> Void

    @State private var nodes: [FileNode] = []
    @State private var scanCompleted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .overlay(PanelyColor.borderSubtle)

            content
        }
        .frame(width: 240)
        .background(PanelyColor.bgSecondary)
        .task(id: taskID) {
            await reload()
        }
    }

    @ViewBuilder
    private var content: some View {
        if rootURL == nil {
            emptyState
        } else if scanCompleted && nodes.isEmpty {
            accessPrompt
        } else {
            tree
        }
    }

    private var header: some View {
        HStack(spacing: PanelySpacing.sm) {
            Image(systemName: "books.vertical")
                .foregroundStyle(PanelyColor.textSecondary)
            Text(rootURL?.lastPathComponent ?? "Library")
                .font(PanelyTypography.body)
                .foregroundStyle(PanelyColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            PanelyIconButton(systemImage: "sidebar.left", action: onHide)
                .help("Hide Library (⌃⌘S)")
        }
        .padding(.horizontal, PanelySpacing.sm)
        .padding(.vertical, PanelySpacing.xs)
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
    }

    private var taskID: String {
        "\(rootURL?.path ?? "")#\(refreshToken.uuidString)"
    }

    private func reload() async {
        guard let rootURL else {
            nodes = []
            scanCompleted = false
            return
        }
        scanCompleted = false
        nodes = await FileNode.loadTree(from: rootURL, maxDepth: 3)
        scanCompleted = true
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

    private var accessPrompt: some View {
        VStack(spacing: PanelySpacing.sm) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(PanelyColor.textSecondary)
            Text("No books to show")
                .font(PanelyTypography.body)
                .foregroundStyle(PanelyColor.textPrimary)
            Text("Pick a folder to browse its contents.")
                .font(PanelyTypography.caption)
                .foregroundStyle(PanelyColor.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: onRequestFolderAccess) {
                Text("Pick Folder…")
                    .font(PanelyTypography.caption)
                    .foregroundStyle(PanelyColor.accentPrimary)
            }
            .buttonStyle(.plain)
            .padding(.top, PanelySpacing.xs)
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
    }
}

#Preview {
    LibrarySidebar(
        rootURL: URL(fileURLWithPath: "/Users/demo/Comics/OnePiece"),
        activeURL: nil,
        refreshToken: UUID(),
        onSelect: { _ in },
        onOpen: {},
        onHide: {},
        onRequestFolderAccess: {}
    )
    .frame(height: 480)
    .background(PanelyColor.bgPrimary)
}
