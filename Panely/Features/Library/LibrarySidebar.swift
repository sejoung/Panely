import SwiftUI

struct LibrarySidebar: View {
    let rootURL: URL?
    let activeURL: URL?
    let refreshToken: UUID
    let pinned: Bool
    let favorites: [FavoriteBook]
    let pageBookmarks: [PageBookmark]
    let volumes: [URL]
    let currentPageIndex: Int
    let onSelect: (URL) -> Void
    let onSelectFavorite: (FavoriteBook) -> Void
    let onRemoveFavorite: (FavoriteBook) -> Void
    let onJumpToBookmark: (PageBookmark) -> Void
    let onRemovePageBookmark: (PageBookmark) -> Void
    let onSelectVolume: (URL) -> Void
    let onOpen: () -> Void
    let onTogglePin: () -> Void
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
        if rootURL == nil && favorites.isEmpty && pageBookmarks.isEmpty && volumes.isEmpty {
            emptyState
        } else if rootURL != nil && scanCompleted && nodes.isEmpty && favorites.isEmpty && pageBookmarks.isEmpty && volumes.isEmpty {
            accessPrompt
        } else {
            tree
        }
    }

    private var header: some View {
        HStack(spacing: PanelySpacing.sm) {
            PanelyIconButton(
                systemImage: "books.vertical",
                action: onRequestFolderAccess
            )
            .help("Change Library Root…")
            Text(rootURL?.lastPathComponent ?? "Library")
                .font(PanelyTypography.body)
                .foregroundStyle(PanelyColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            PanelyIconButton(
                systemImage: pinned ? "pin.fill" : "pin",
                isActive: pinned,
                action: onTogglePin
            )
            .help(pinned ? "Unpin Library (⌃⌘S)" : "Pin Library Open (⌃⌘S)")
        }
        .padding(.horizontal, PanelySpacing.sm)
        .padding(.vertical, PanelySpacing.xs)
    }

    private var tree: some View {
        // Standardize the active URL once instead of per-row. `standardizedFileURL`
        // resolves symlinks/relatives on every call, so hoisting it spares N
        // redundant evaluations across Volumes + Files sections.
        let activeStdURL = activeURL?.standardizedFileURL
        return List {
            if volumes.count > 1 {
                Section(header: sectionHeader("Volumes", systemImage: "books.vertical.fill")) {
                    ForEach(volumes, id: \.self) { url in
                        VolumeRow(
                            url: url,
                            isActive: activeStdURL == url.standardizedFileURL,
                            onTap: { onSelectVolume(url) }
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            }

            if !favorites.isEmpty {
                Section(header: sectionHeader("Favorites", systemImage: "star.fill")) {
                    ForEach(favorites) { fav in
                        FavoriteRow(
                            favorite: fav,
                            isActive: activeURL?.path == fav.path,
                            onTap: { onSelectFavorite(fav) },
                            onRemove: { onRemoveFavorite(fav) }
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            }

            if !pageBookmarks.isEmpty {
                Section(header: sectionHeader("Bookmarks", systemImage: "bookmark.fill")) {
                    ForEach(pageBookmarks) { bm in
                        PageBookmarkRow(
                            bookmark: bm,
                            isCurrent: bm.pageIndex == currentPageIndex,
                            onTap: { onJumpToBookmark(bm) },
                            onRemove: { onRemovePageBookmark(bm) }
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            }

            if !nodes.isEmpty {
                Section(header: sectionHeader("Files", systemImage: "folder")) {
                    OutlineGroup(nodes, children: \.children) { node in
                        FileNodeRow(
                            node: node,
                            isActive: activeStdURL == node.url.standardizedFileURL,
                            onTap: { onSelect(node.url) }
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
            Text(title)
                .font(PanelyTypography.caption)
        }
        .foregroundStyle(PanelyColor.textSecondary)
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

        // Two-phase load: ship the shallow (depth-1) tree immediately so the
        // sidebar fills in fast on big libraries (was 1–2 s of blank for
        // 10 k-file libraries when the depth-3 scan ran serially), then
        // replace with the deeper tree once the background scan finishes.
        let shallow = await FileNode.loadTree(from: rootURL, maxDepth: 1)
        if Task.isCancelled { return }
        nodes = shallow
        scanCompleted = true

        let deep = await FileNode.loadTree(from: rootURL, maxDepth: 3)
        if Task.isCancelled { return }
        // Skip the swap if the deep tree didn't add anything (avoids a
        // redundant SwiftUI render for shallow libraries).
        if deep != shallow {
            nodes = deep
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

private struct FavoriteRow: View {
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

private struct VolumeRow: View {
    let url: URL
    let isActive: Bool
    let onTap: () -> Void

    private let iconName: String
    private let displayName: String

    init(url: URL, isActive: Bool, onTap: @escaping () -> Void) {
        self.url = url
        self.isActive = isActive
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
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

private struct PageBookmarkRow: View {
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

#Preview {
    LibrarySidebar(
        rootURL: URL(fileURLWithPath: "/Users/demo/Comics/OnePiece"),
        activeURL: nil,
        refreshToken: UUID(),
        pinned: false,
        favorites: [],
        pageBookmarks: [],
        volumes: [],
        currentPageIndex: 0,
        onSelect: { _ in },
        onSelectFavorite: { _ in },
        onRemoveFavorite: { _ in },
        onJumpToBookmark: { _ in },
        onRemovePageBookmark: { _ in },
        onSelectVolume: { _ in },
        onOpen: {},
        onTogglePin: {},
        onRequestFolderAccess: {}
    )
    .frame(height: 480)
    .background(PanelyColor.bgPrimary)
}
