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
            layout: viewModel.layout,
            direction: viewModel.direction,
            fitMode: viewModel.fitMode,
            sidebarPinned: viewModel.sidebarPinned,
            onOpen: { viewModel.openSource() },
            onPrev: { viewModel.previous() },
            onNext: { viewModel.next() },
            onSetLayout: { viewModel.setLayout($0) },
            onToggleDirection: { viewModel.toggleDirection() },
            onSetFitMode: { viewModel.setFitMode($0) },
            onToggleSidebarPin: { viewModel.toggleSidebarPin() },
            onZoomIn: { viewerController.zoomIn() },
            onZoomOut: { viewerController.zoomOut() },
            autoFitOnResize: viewModel.autoFitOnResize,
            onToggleAutoFit: { viewModel.toggleAutoFitOnResize() },
            toolbarPinned: viewModel.toolbarPinned,
            onToggleToolbarPin: { viewModel.toggleToolbarPin() },
            showVolumeNav: viewModel.hasMultipleVolumes,
            canGoPreviousVolume: viewModel.canGoPreviousVolume,
            canGoNextVolume: viewModel.canGoNextVolume,
            onPreviousVolume: { viewModel.previousVolume() },
            onNextVolume: { viewModel.nextVolume() },
            hasSource: viewModel.hasSource,
            isBookFavorite: viewModel.isCurrentBookFavorite,
            isPageBookmarked: viewModel.isCurrentPageBookmarked,
            onToggleFavorite: { viewModel.toggleFavoriteForCurrentBook() },
            onTogglePageBookmark: { viewModel.toggleCurrentPageBookmark() },
            thumbnailSidebarVisible: viewModel.thumbnailSidebarVisible,
            onToggleThumbnailSidebar: { viewModel.toggleThumbnailSidebar() }
        )
        .padding(PanelySpacing.md)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(PanelyMotion.uiReveal, value: shown)
    }
}
