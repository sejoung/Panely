import SwiftUI

struct ReaderScene: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @Environment(ViewerController.self) private var viewerController
    @State private var toolbarVisible = false
    @State private var sidebarDismissTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    private let revealZoneHeight: CGFloat = 80
    private let sidebarRevealDelayMs: Int = 200
    private let sidebarDismissDelayMs: Int = 300

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                if viewModel.sidebarPinned {
                    sidebarView
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                viewerArea
                if viewModel.thumbnailSidebarVisible && viewModel.hasSource {
                    thumbnailSidebar
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            if !viewModel.sidebarPinned {
                HotEdgeReveal(
                    delayMs: sidebarRevealDelayMs,
                    onReveal: { viewModel.revealSidebarOverlay() }
                )
                .frame(width: 12)
            }

            if !viewModel.sidebarPinned && viewModel.sidebarOverlayVisible {
                sidebarView
                    .shadow(color: .black.opacity(0.45), radius: 14, x: 4, y: 0)
                    .transition(.move(edge: .leading))
                    .onHover { hovering in
                        if hovering {
                            cancelSidebarDismiss()
                        } else {
                            scheduleSidebarDismiss()
                        }
                    }
            }
        }
        .animation(PanelyMotion.uiReveal, value: viewModel.sidebarPinned)
        .animation(PanelyMotion.uiReveal, value: viewModel.sidebarOverlayVisible)
        .animation(PanelyMotion.uiReveal, value: viewModel.thumbnailSidebarVisible)
        .overlay {
            if viewModel.isLoading {
                LoadingOverlay(message: viewModel.loadingMessage)
            }
        }
        .animation(PanelyMotion.uiReveal, value: viewModel.isLoading)
        .frame(minWidth: 800, minHeight: 600)
    }

    private var sidebarView: some View {
        LibrarySidebar(
            rootURL: viewModel.libraryRootURL,
            activeURL: viewModel.currentSourceURL,
            refreshToken: viewModel.libraryRefreshToken,
            pinned: viewModel.sidebarPinned,
            favorites: viewModel.bookmarks.favorites,
            pageBookmarks: viewModel.currentBookPageBookmarks,
            volumes: viewModel.sidebarVolumes,
            currentPageIndex: viewModel.currentPageIndex,
            onSelect: { url in
                viewModel.openURL(url)
                viewModel.dismissSidebarOverlay()
                isFocused = true
            },
            onSelectFavorite: { fav in
                viewModel.openFavorite(fav)
                viewModel.dismissSidebarOverlay()
                isFocused = true
            },
            onRemoveFavorite: { fav in
                viewModel.bookmarks.removeFavorite(fav)
            },
            onJumpToBookmark: { bm in
                viewModel.jumpToBookmark(bm)
                isFocused = true
            },
            onRemovePageBookmark: { bm in
                guard let key = viewModel.currentPositionKey else { return }
                viewModel.bookmarks.removePageBookmark(forKey: key, id: bm.id)
            },
            onSelectVolume: { url in
                viewModel.openURL(url)
                isFocused = true
            },
            onOpen: {
                viewModel.openSource()
                viewModel.dismissSidebarOverlay()
            },
            onTogglePin: { viewModel.toggleSidebarPin() },
            onRequestFolderAccess: { viewModel.requestFolderAccess() }
        )
    }

    private var thumbnailSidebar: some View {
        ThumbnailSidebar(
            pages: viewModel.source.pages,
            pageDimensions: viewModel.pageDimensions,
            currentPageIndex: viewModel.currentPageIndex,
            onJump: { idx in
                viewModel.jump(to: idx)
                isFocused = true
            },
            onClose: { viewModel.toggleThumbnailSidebar() }
        )
    }

    private var viewerArea: some View {
        GeometryReader { geo in
            ViewerContainer(
                images: viewModel.currentImages,
                direction: viewModel.effectiveDirection,
                fitMode: viewModel.fitMode,
                layout: viewModel.layout,
                pageIndex: viewModel.currentPageIndex,
                identity: viewerIdentity,
                onPageIndexChanged: { idx in viewModel.setCurrentPageFromScroll(idx) },
                onVisibleRangeChanged: { range in viewModel.setVisibleRange(range) },
                autoFitOnResize: viewModel.autoFitOnResize,
                viewerController: viewerController
            )
            .overlay(alignment: .top) {
                TitleBarPassthrough()
                    .frame(height: 28)
                    .ignoresSafeArea(edges: .top)
            }
            .overlay(alignment: .top) { toolbarOverlay }
            .overlay(alignment: .bottom) { sliderOverlay }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let isTop = location.y < revealZoneHeight
                    let isBottom = location.y > geo.size.height - revealZoneHeight
                    toolbarVisible = isTop || isBottom
                case .ended:
                    toolbarVisible = false
                }
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) {
                viewModel.effectiveDirection.isRTL ? viewModel.next() : viewModel.previous()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                viewModel.effectiveDirection.isRTL ? viewModel.previous() : viewModel.next()
                return .handled
            }
            .onKeyPress(.space) {
                viewModel.next()
                return .handled
            }
            .onKeyPress(.escape) {
                if viewModel.sidebarOverlayVisible {
                    viewModel.dismissSidebarOverlay()
                    return .handled
                }
                return .ignored
            }
            .onAppear { isFocused = true }
            .onChange(of: viewModel.currentSourceURL) { _, _ in
                isFocused = true
            }
        }
    }

    /// Combined visibility — pinned overrides hover-driven auto-hide.
    private var toolbarShown: Bool { toolbarVisible || viewModel.toolbarPinned }

    private var toolbarOverlay: some View {
        PanelyToolbar(
            layout: viewModel.layout,
            direction: viewModel.direction,
            fitMode: viewModel.fitMode,
            sidebarPinned: viewModel.sidebarPinned,
            onOpen: { viewModel.openSource() },
            onPrev: { viewModel.previous() },
            onNext: { viewModel.next() },
            onToggleLayout: { viewModel.toggleLayout() },
            onToggleDirection: { viewModel.toggleDirection() },
            onToggleFitMode: { viewModel.toggleFitMode() },
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
        .opacity(toolbarShown ? 1 : 0)
        .allowsHitTesting(toolbarShown)
        .animation(PanelyMotion.uiReveal, value: toolbarShown)
    }

    @ViewBuilder
    private var sliderOverlay: some View {
        if viewModel.hasSource && viewModel.totalPages > 1 {
            VStack(spacing: PanelySpacing.xs) {
                HStack(spacing: 0) {
                    if let vol = viewModel.volumeCounterLabel {
                        Text("\(vol) · ")
                            .font(PanelyTypography.caption)
                            .foregroundStyle(PanelyColor.textSecondary)
                    }
                    QuickJumpField(
                        currentPage: viewModel.currentPageNumber,
                        rangeEndPage: viewModel.currentPageRangeEndNumber,
                        totalPages: viewModel.totalPages,
                        onJump: { viewModel.jump(toPageNumber: $0) }
                    )
                }

                PanelySlider(
                    value: sliderBinding,
                    range: 0...Double(viewModel.totalPages - 1)
                )
            }
            .padding(.horizontal, PanelySpacing.xl)
            .padding(.bottom, PanelySpacing.lg)
            .opacity(toolbarShown ? 1 : 0)
            .allowsHitTesting(toolbarShown)
            .animation(PanelyMotion.uiReveal, value: toolbarShown)
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.currentPageIndex) },
            set: { viewModel.jump(to: Int($0.rounded())) }
        )
    }

    private var viewerIdentity: String {
        // Identity changes ONLY when the source changes — that's what
        // triggers force-reset of magnification (a new book legitimately
        // resets fit). Layout-driven stack rebuilds happen automatically
        // inside ImageStackView.setImages (count + axis comparison), no
        // need to encode the layout here. Including it would otherwise
        // override the lock and defeat user-zoom preservation.
        viewModel.currentSourceURL?.path ?? ""
    }

    private func scheduleSidebarDismiss() {
        sidebarDismissTask?.cancel()
        let delay = sidebarDismissDelayMs
        sidebarDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            viewModel.dismissSidebarOverlay()
        }
    }

    private func cancelSidebarDismiss() {
        sidebarDismissTask?.cancel()
        sidebarDismissTask = nil
    }
}

private struct HotEdgeReveal: View {
    let delayMs: Int
    let onReveal: () -> Void
    @State private var hoverTask: Task<Void, Never>?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .contentShape(Rectangle())
            Rectangle()
                .fill(hovering ? PanelyColor.accentPrimary.opacity(0.35) : Color.clear)
                .frame(width: 3)
                .allowsHitTesting(false)
        }
        .onHover { isHovering in
            hovering = isHovering
            hoverTask?.cancel()
            if isHovering {
                let delay = delayMs
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled else { return }
                    onReveal()
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

#Preview {
    ReaderScene()
        .environment(ReaderViewModel())
        .environment(ViewerController())
}
