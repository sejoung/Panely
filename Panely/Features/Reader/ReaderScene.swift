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
            onSelect: { url in
                viewModel.openURL(url)
                viewModel.dismissSidebarOverlay()
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
            showVolumeNav: viewModel.hasMultipleVolumes,
            canGoPreviousVolume: viewModel.canGoPreviousVolume,
            canGoNextVolume: viewModel.canGoNextVolume,
            onPreviousVolume: { viewModel.previousVolume() },
            onNextVolume: { viewModel.nextVolume() }
        )
        .padding(PanelySpacing.md)
        .opacity(toolbarVisible ? 1 : 0)
        .allowsHitTesting(toolbarVisible)
        .animation(PanelyMotion.uiReveal, value: toolbarVisible)
    }

    @ViewBuilder
    private var sliderOverlay: some View {
        if viewModel.hasSource && viewModel.totalPages > 1 {
            VStack(spacing: PanelySpacing.xs) {
                Text(viewModel.combinedCounterLabel)
                    .font(PanelyTypography.caption)
                    .foregroundStyle(PanelyColor.textSecondary)

                PanelySlider(
                    value: sliderBinding,
                    range: 0...Double(viewModel.totalPages - 1)
                )
            }
            .padding(.horizontal, PanelySpacing.xl)
            .padding(.bottom, PanelySpacing.lg)
            .opacity(toolbarVisible ? 1 : 0)
            .allowsHitTesting(toolbarVisible)
            .animation(PanelyMotion.uiReveal, value: toolbarVisible)
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.currentPageIndex) },
            set: { viewModel.jump(to: Int($0.rounded())) }
        )
    }

    private var viewerIdentity: String {
        // Include layout so the viewer rebuilds the image stack when toggling
        // between paged and vertical modes (different visiblePages set).
        "\(viewModel.currentSourceURL?.path ?? "")#\(viewModel.layout.rawValue)"
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
