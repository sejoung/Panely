import SwiftUI

/// Mirrors `PanelyToolbarActions`: bundles every callback the sidebar needs
/// so the host (and previews) build one struct instead of threading nine
/// closures through `LibrarySidebar`'s initializer.
struct LibrarySidebarActions {
    var onSelect: (URL) -> Void = { _ in }
    var onSelectFavorite: (FavoriteBook) -> Void = { _ in }
    var onRemoveFavorite: (FavoriteBook) -> Void = { _ in }
    var onJumpToBookmark: (PageBookmark) -> Void = { _ in }
    var onRemovePageBookmark: (PageBookmark) -> Void = { _ in }
    var onSelectVolume: (URL) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onContinueReading: () -> Void = {}
    var onRequestFolderAccess: () -> Void = {}
}

struct LibrarySidebar: View {
    let rootURL: URL?
    let activeURL: URL?
    let refreshToken: UUID
    let pinned: Bool
    let favorites: [FavoriteBook]
    let pageBookmarks: [PageBookmark]
    let volumes: [URL]
    let libraryTreeLoader: any LibraryTreeLoading
    let currentPageIndex: Int
    var readingBadge: (URL) -> ReadingBadge? = { _ in nil }
    var continueReadingTitle: String? = nil
    var continueReadingFraction: Double = 0
    let actions: LibrarySidebarActions

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

    /// True when there's nothing in any of the sidebar's non-tree sections
    /// (favorites / page bookmarks / volumes).
    private var hasSidebarExtras: Bool {
        !favorites.isEmpty || !pageBookmarks.isEmpty || !volumes.isEmpty
    }

    @ViewBuilder
    private var content: some View {
        if rootURL == nil && !hasSidebarExtras {
            emptyState
        } else if rootURL != nil && model.scanCompleted && model.nodes.isEmpty && !hasSidebarExtras {
            accessPrompt
        } else {
            tree
        }
    }

    private var header: some View {
        HStack(spacing: PanelySpacing.sm) {
            PanelyIconButton(
                systemImage: "books.vertical",
                action: actions.onRequestFolderAccess
            )
            .help("Change Library Root…")
            Text(rootURL?.lastPathComponent ?? "Library")
                .font(PanelyTypography.body)
                .foregroundStyle(PanelyColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            PanelyIconButton(
                systemImage: "arrow.clockwise",
                accessibilityTitle: "Refresh File Tree",
                action: actions.onRefresh
            )
            .help("Refresh File Tree")
            .disabled(rootURL == nil)
            PanelyIconButton(
                systemImage: pinned ? "pin.fill" : "pin",
                isActive: pinned,
                action: actions.onTogglePin
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
            continueReadingSection()
            volumesSection(activeStdURL: activeStdURL)
            favoritesSection(activeStdURL: activeStdURL)
            bookmarksSection
            filesSection(activeStdURL: activeStdURL)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func continueReadingSection() -> some View {
        if let title = continueReadingTitle {
            Section(header: sectionHeader("Continue Reading", systemImage: "book.fill")) {
                Button(action: actions.onContinueReading) {
                    HStack(spacing: PanelySpacing.sm) {
                        Image(systemName: "book.fill")
                            .foregroundStyle(PanelyColor.accentPrimary)
                            .frame(width: 16)
                        Text(title)
                            .font(PanelyTypography.body)
                            .foregroundStyle(PanelyColor.textPrimary)
                            .lineLimit(1)
                            // Match the file tree: keep the trailing volume
                            // number visible instead of clipping it with a
                            // tail ellipsis.
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        ReadingBadgeView(badge: .inProgress(fraction: continueReadingFraction))
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 2)
                    .help(title)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    private func volumesSection(activeStdURL: URL?) -> some View {
        if volumes.count > 1 {
            Section(header: sectionHeader("Volumes", systemImage: "books.vertical.fill")) {
                ForEach(volumes, id: \.self) { url in
                    VolumeRow(
                        url: url,
                        isActive: isActiveVolume(url, activeURL: activeStdURL),
                        badge: readingBadge(url),
                        onTap: { actions.onSelectVolume(url) }
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    private func isActiveVolume(_ volumeURL: URL, activeURL: URL?) -> Bool {
        guard let activeURL else { return false }
        let volume = volumeURL.standardizedFileURL
        return volume == activeURL || volume.isAncestor(of: activeURL)
    }

    @ViewBuilder
    private func favoritesSection(activeStdURL: URL?) -> some View {
        if !favorites.isEmpty {
            Section(header: sectionHeader("Favorites", systemImage: "star.fill")) {
                ForEach(favorites) { fav in
                    FavoriteRow(
                        favorite: fav,
                        isActive: isFavorite(fav, activeFor: activeStdURL),
                        onTap: { actions.onSelectFavorite(fav) },
                        onRemove: { actions.onRemoveFavorite(fav) }
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
                        onTap: { actions.onJumpToBookmark(bm) },
                        onRemove: { actions.onRemovePageBookmark(bm) }
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
                        readingBadge: readingBadge,
                        onSelect: actions.onSelect
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
            Button(action: actions.onOpen) {
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
            Button(action: actions.onRequestFolderAccess) {
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
    let readingBadge: (URL) -> ReadingBadge?
    let onSelect: (URL) -> Void

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(isExpanded: expansionBinding(for: node.id)) {
                ForEach(children) { child in
                    FileTreeNodeRow(
                        node: child,
                        activeStdURL: activeStdURL,
                        expandedNodeIDs: $expandedNodeIDs,
                        readingBadge: readingBadge,
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
            badge: readingBadge(node.url),
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
        libraryTreeLoader: LiveLibraryTreeLoader(),
        currentPageIndex: 0,
        actions: LibrarySidebarActions()
    )
    .frame(height: 480)
    .background(PanelyColor.bgPrimary)
}
