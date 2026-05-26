import SwiftUI

/// Wires the project-wide `LibrarySidebar` to `ReaderViewModel` actions. The
/// sidebar itself stays presentation-only — opening a book, dismissing the
/// overlay, and re-focusing the viewer all funnel through here so the
/// sidebar component doesn't need to know about the viewmodel.
struct SidebarHost: View {
    @Environment(ReaderViewModel.self) private var viewModel
    let requestFocus: () -> Void

    var body: some View {
        LibrarySidebar(
            rootURL: viewModel.libraryRootURL,
            activeURL: viewModel.sidebarActiveURL,
            refreshToken: viewModel.libraryRefreshToken,
            pinned: viewModel.sidebarPinned,
            favorites: viewModel.favorites.favorites,
            pageBookmarks: viewModel.currentBookPageBookmarks,
            volumes: viewModel.sidebarVolumes,
            libraryTreeLoader: viewModel.dependencies.libraryTreeLoader,
            currentPageIndex: viewModel.currentPageIndex,
            actions: sidebarActions
        )
    }

    private var sidebarActions: LibrarySidebarActions {
        LibrarySidebarActions(
            onSelect: { url in
                viewModel.openLibraryURL(url)
                viewModel.dismissSidebarOverlay()
                requestFocus()
            },
            onSelectFavorite: { fav in
                viewModel.openFavorite(fav)
                viewModel.dismissSidebarOverlay()
                requestFocus()
            },
            onRemoveFavorite: { fav in
                viewModel.favorites.removeFavorite(fav)
            },
            onJumpToBookmark: { bm in
                viewModel.jumpToBookmark(bm)
                requestFocus()
            },
            onRemovePageBookmark: { bm in
                guard let key = viewModel.currentPositionKey else { return }
                viewModel.pageBookmarks.removePageBookmark(forKey: key, id: bm.id)
            },
            onSelectVolume: { url in
                viewModel.openURL(url)
                requestFocus()
            },
            onOpen: {
                viewModel.openSource()
                viewModel.dismissSidebarOverlay()
            },
            onTogglePin: { viewModel.toggleSidebarPin() },
            onRequestFolderAccess: { viewModel.requestFolderAccess() }
        )
    }
}
