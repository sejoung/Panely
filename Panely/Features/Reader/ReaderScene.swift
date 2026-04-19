import SwiftUI

struct ReaderScene: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @State private var toolbarVisible = false
    @FocusState private var isFocused: Bool

    private let revealZoneHeight: CGFloat = 80

    var body: some View {
        HStack(spacing: 0) {
            if viewModel.sidebarVisible {
                LibrarySidebar(
                    rootURL: viewModel.libraryRootURL,
                    activeURL: viewModel.currentSourceURL,
                    refreshToken: viewModel.libraryRefreshToken,
                    onSelect: { url in
                        viewModel.openURL(url)
                        isFocused = true
                    },
                    onOpen: { viewModel.openSource() },
                    onHide: { viewModel.toggleSidebar() },
                    onRequestFolderAccess: { viewModel.requestFolderAccess() }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            viewerArea
        }
        .animation(PanelyMotion.uiReveal, value: viewModel.sidebarVisible)
        .overlay(alignment: .topLeading) {
            if !viewModel.sidebarVisible && !toolbarVisible {
                showSidebarHandle
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    private var showSidebarHandle: some View {
        PanelyIconButton(
            systemImage: "sidebar.left",
            action: { viewModel.toggleSidebar() }
        )
        .help("Show Library (⌃⌘S)")
        .padding(PanelySpacing.sm)
        .transition(.opacity)
    }

    private var viewerArea: some View {
        GeometryReader { geo in
            ViewerContainer(
                images: viewModel.currentImages,
                direction: viewModel.direction,
                fitMode: viewModel.fitMode,
                identity: viewerIdentity
            )
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
                viewModel.direction.isRTL ? viewModel.next() : viewModel.previous()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                viewModel.direction.isRTL ? viewModel.previous() : viewModel.next()
                return .handled
            }
            .onKeyPress(.space) {
                viewModel.next()
                return .handled
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
            sidebarVisible: viewModel.sidebarVisible,
            onOpen: { viewModel.openSource() },
            onPrev: { viewModel.previous() },
            onNext: { viewModel.next() },
            onToggleLayout: { viewModel.toggleLayout() },
            onToggleDirection: { viewModel.toggleDirection() },
            onToggleFitMode: { viewModel.toggleFitMode() },
            onToggleSidebar: { viewModel.toggleSidebar() },
            showVolumeNav: viewModel.hasMultipleVolumes,
            canGoPreviousVolume: viewModel.canGoPreviousVolume,
            canGoNextVolume: viewModel.canGoNextVolume,
            onPreviousVolume: { viewModel.previousVolume() },
            onNextVolume: { viewModel.nextVolume() }
        )
        .padding(PanelySpacing.md)
        .opacity(toolbarVisible ? 1 : 0)
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
        "\(viewModel.currentSourceURL?.path ?? "")#\(viewModel.currentPageIndex)"
    }
}

#Preview {
    ReaderScene()
        .environment(ReaderViewModel())
}
