import SwiftUI

struct ReaderScene: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @State private var toolbarVisible = false
    @FocusState private var isFocused: Bool

    private let revealZoneHeight: CGFloat = 80

    var body: some View {
        ViewerContainer(
            images: viewModel.currentImages,
            direction: viewModel.direction
        )
        .overlay(alignment: .top) { toolbarOverlay }
        .overlay(alignment: .bottom) { sliderOverlay }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                toolbarVisible = location.y < revealZoneHeight
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
        .frame(minWidth: 800, minHeight: 600)
    }

    private var toolbarOverlay: some View {
        PanelyToolbar(
            layout: viewModel.layout,
            direction: viewModel.direction,
            onOpen: { viewModel.openSource() },
            onPrev: { viewModel.previous() },
            onNext: { viewModel.next() },
            onToggleLayout: { viewModel.toggleLayout() },
            onToggleDirection: { viewModel.toggleDirection() },
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
}

#Preview {
    ReaderScene()
        .environment(ReaderViewModel())
}
