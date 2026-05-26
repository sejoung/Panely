import Foundation

extension ReaderViewModel {
    /// Snapshot of the fields `PanelyToolbar` reads. Computed each render so
    /// the toolbar always reflects current viewmodel state — adding a new
    /// toolbar control means adding a field here and on `PanelyToolbarState`,
    /// not threading another parameter through `ReaderToolbarOverlay`.
    var toolbarState: PanelyToolbarState {
        PanelyToolbarState(
            layout: layout,
            direction: direction,
            fitMode: fitMode,
            sidebarPinned: sidebarPinned,
            autoFitOnResize: autoFitOnResize,
            toolbarPinned: toolbarPinned,
            showVolumeNav: hasMultipleVolumes,
            canGoPreviousVolume: canGoPreviousVolume,
            canGoNextVolume: canGoNextVolume,
            hasSource: hasSource,
            isBookFavorite: isCurrentBookFavorite,
            isPageBookmarked: isCurrentPageBookmarked,
            thumbnailSidebarVisible: thumbnailSidebarVisible
        )
    }

    /// Builds the toolbar action bundle. Zoom routes through `ViewerController`
    /// (which owns the AppKit scroll view), so it has to be passed in — the
    /// viewmodel doesn't know about that layer.
    func toolbarActions(viewerController: ViewerController) -> PanelyToolbarActions {
        PanelyToolbarActions(
            onOpen: { [self] in openSource() },
            onPrev: { [self] in previous() },
            onNext: { [self] in next() },
            onSetLayout: { [self] in setLayout($0) },
            onToggleDirection: { [self] in toggleDirection() },
            onSetFitMode: { [self] in setFitMode($0) },
            onToggleSidebarPin: { [self] in toggleSidebarPin() },
            onZoomIn: { viewerController.zoomIn() },
            onZoomOut: { viewerController.zoomOut() },
            onToggleAutoFit: { [self] in toggleAutoFitOnResize() },
            onToggleToolbarPin: { [self] in toggleToolbarPin() },
            onPreviousVolume: { [self] in previousVolume() },
            onNextVolume: { [self] in nextVolume() },
            onToggleFavorite: { [self] in toggleFavoriteForCurrentBook() },
            onTogglePageBookmark: { [self] in toggleCurrentPageBookmark() },
            onToggleThumbnailSidebar: { [self] in toggleThumbnailSidebar() }
        )
    }
}
