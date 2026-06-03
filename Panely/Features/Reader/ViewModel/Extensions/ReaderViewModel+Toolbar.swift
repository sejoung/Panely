import Foundation

extension ReaderViewModel {
    /// Snapshot of the fields `PanelyToolbar` reads. Computed each render so
    /// the toolbar always reflects current viewmodel state — adding a new
    /// toolbar control means adding a field here and on `PanelyToolbarState`,
    /// not threading another parameter through `ReaderToolbarOverlay`.
    ///
    /// `isAtFit` lives on `ViewerController` (it tracks AppKit-side scroll
    /// magnification), so the overlay supplies it. Defaults to `true` so the
    /// viewmodel-only callsites get the historical "highlight the current
    /// fit" behaviour without needing a viewer reference.
    func toolbarState(isAtFit: Bool = true) -> PanelyToolbarState {
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
            thumbnailSidebarVisible: thumbnailSidebarVisible,
            doublePageCoverAlone: doublePageCoverAlone,
            isAtFit: isAtFit
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
            onSetFitMode: { [self] target in
                // Picking a *different* fit mode goes through the viewmodel —
                // the fitMode prop change drives `applyFit` with `force=true`
                // via the AppKit diff. Re-pressing the *same* fit mode would
                // be a viewmodel no-op (the value didn't change), so route
                // it through `resetZoom` instead — that's the user saying
                // "I'm done zooming, snap me back to fit."
                if fitMode == target {
                    viewerController.resetZoom()
                } else {
                    setFitMode(target)
                }
            },
            onToggleSidebarPin: { [self] in toggleSidebarPin() },
            onZoomIn: { viewerController.zoomIn() },
            onZoomOut: { viewerController.zoomOut() },
            onToggleAutoFit: { [self] in toggleAutoFitOnResize() },
            onToggleToolbarPin: { [self] in toggleToolbarPin() },
            onPreviousVolume: { [self] in previousVolume() },
            onNextVolume: { [self] in nextVolume() },
            onToggleFavorite: { [self] in toggleFavoriteForCurrentBook() },
            onTogglePageBookmark: { [self] in toggleCurrentPageBookmark() },
            onToggleThumbnailSidebar: { [self] in toggleThumbnailSidebar() },
            onToggleDoublePageCoverAlone: { [self] in toggleDoublePageCoverAlone() }
        )
    }
}
