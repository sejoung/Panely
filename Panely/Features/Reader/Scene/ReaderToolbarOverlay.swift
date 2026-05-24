import SwiftUI

/// The floating toolbar shown along the top edge of the viewer. Wires
/// `PanelyToolbar` (presentation-only) to viewmodel + viewer controller
/// actions and applies the show/hide opacity gate.
struct ReaderToolbarOverlay: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @Environment(ViewerController.self) private var viewerController
    let shown: Bool

    var body: some View {
        PanelyToolbar(
            state: PanelyToolbarState(
                layout: viewModel.layout,
                direction: viewModel.direction,
                fitMode: viewModel.fitMode,
                sidebarPinned: viewModel.sidebarPinned,
                autoFitOnResize: viewModel.autoFitOnResize,
                toolbarPinned: viewModel.toolbarPinned,
                showVolumeNav: viewModel.hasMultipleVolumes,
                canGoPreviousVolume: viewModel.canGoPreviousVolume,
                canGoNextVolume: viewModel.canGoNextVolume,
                hasSource: viewModel.hasSource,
                isBookFavorite: viewModel.isCurrentBookFavorite,
                isPageBookmarked: viewModel.isCurrentPageBookmarked,
                thumbnailSidebarVisible: viewModel.thumbnailSidebarVisible
            ),
            actions: PanelyToolbarActions(
                onOpen: { viewModel.openSource() },
                onPrev: { viewModel.previous() },
                onNext: { viewModel.next() },
                onSetLayout: { viewModel.setLayout($0) },
                onToggleDirection: { viewModel.toggleDirection() },
                onSetFitMode: { viewModel.setFitMode($0) },
                onToggleSidebarPin: { viewModel.toggleSidebarPin() },
                onZoomIn: { viewerController.zoomIn() },
                onZoomOut: { viewerController.zoomOut() },
                onToggleAutoFit: { viewModel.toggleAutoFitOnResize() },
                onToggleToolbarPin: { viewModel.toggleToolbarPin() },
                onPreviousVolume: { viewModel.previousVolume() },
                onNextVolume: { viewModel.nextVolume() },
                onToggleFavorite: { viewModel.toggleFavoriteForCurrentBook() },
                onTogglePageBookmark: { viewModel.toggleCurrentPageBookmark() },
                onToggleThumbnailSidebar: { viewModel.toggleThumbnailSidebar() }
            )
        )
        .padding(PanelySpacing.md)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(PanelyMotion.uiReveal, value: shown)
    }
}
