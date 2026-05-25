import SwiftUI

struct LibrarySidebar: View {
    let rootURL: URL?
    let activeURL: URL?
    let refreshToken: UUID
    let pinned: Bool
    let favorites: [FavoriteBook]
    let pageBookmarks: [PageBookmark]
    let volumes: [URL]
    var libraryTreeLoader: any LibraryTreeLoading = LiveLibraryTreeLoader()
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

    @State private var model = LibrarySidebarModel()

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
            await model.reload(rootURL: rootURL, activeURL: activeURL, loader: libraryTreeLoader)
        }
        .onChange(of: activeURL) { _, newValue in
            model.expandAncestors(of: newValue)
        }
    }

    @ViewBuilder
    private var content: some View {
        if rootURL == nil && favorites.isEmpty && pageBookmarks.isEmpty && volumes.isEmpty {
            emptyState
        } else if rootURL != nil && model.scanCompleted && model.nodes.isEmpty && favorites.isEmpty && pageBookmarks.isEmpty && volumes.isEmpty {
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
            volumesSection(activeStdURL: activeStdURL)
            favoritesSection(activeStdURL: activeStdURL)
            bookmarksSection
            filesSection(activeStdURL: activeStdURL)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func volumesSection(activeStdURL: URL?) -> some View {
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
    }

    @ViewBuilder
    private func favoritesSection(activeStdURL: URL?) -> some View {
        if !favorites.isEmpty {
            Section(header: sectionHeader("Favorites", systemImage: "star.fill")) {
                ForEach(favorites) { fav in
                    FavoriteRow(
                        favorite: fav,
                        isActive: isFavorite(fav, activeFor: activeStdURL),
                        onTap: { onSelectFavorite(fav) },
                        onRemove: { onRemoveFavorite(fav) }
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    @ViewBuilder
    private var bookmarksSection: some View {
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
    }

    @ViewBuilder
    private func filesSection(activeStdURL: URL?) -> some View {
        if !model.nodes.isEmpty {
            Section(header: sectionHeader("Files", systemImage: "folder")) {
                ForEach(model.nodes) { node in
                    FileTreeNodeRow(
                        node: node,
                        activeStdURL: activeStdURL,
                        expandedNodeIDs: $model.expandedNodeIDs,
                        onSelect: onSelect
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
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

    private func isFavorite(_ favorite: FavoriteBook, activeFor activeStdURL: URL?) -> Bool {
        guard let activePath = activeStdURL?.path else { return false }
        if let innerPath = favorite.innerPath {
            return activePath.hasSuffix("/" + innerPath)
        }
        return activePath == URL(fileURLWithPath: favorite.path).standardizedFileURL.path
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

private struct FileTreeNodeRow: View {
    let node: FileNode
    let activeStdURL: URL?
    @Binding var expandedNodeIDs: Set<URL>
    let onSelect: (URL) -> Void

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(isExpanded: expansionBinding(for: node.id)) {
                ForEach(children) { child in
                    FileTreeNodeRow(
                        node: child,
                        activeStdURL: activeStdURL,
                        expandedNodeIDs: $expandedNodeIDs,
                        onSelect: onSelect
                    )
                }
            } label: {
                row
            }
        } else {
            row
        }
    }

    private var row: some View {
        FileNodeRow(
            node: node,
            isActive: activeStdURL == node.url.standardizedFileURL,
            onTap: { onSelect(node.url) }
        )
    }

    private func expansionBinding(for id: URL) -> Binding<Bool> {
        Binding(
            get: { expandedNodeIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedNodeIDs.insert(id)
                } else {
                    expandedNodeIDs.remove(id)
                }
            }
        )
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
