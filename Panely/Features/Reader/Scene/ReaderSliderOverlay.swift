import SwiftUI

/// Bottom-anchored page slider plus the quick-jump field. Mirrors the
/// toolbar's show/hide behaviour via `shown`. Hidden entirely when the
/// loaded book has fewer than two pages — a one-page book has nothing to
/// slide between.
struct ReaderSliderOverlay: View {
    @Environment(ReaderViewModel.self) private var viewModel
    let shown: Bool

    var body: some View {
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
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .animation(PanelyMotion.uiReveal, value: shown)
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.currentPageIndex) },
            set: { viewModel.jump(to: Int($0.rounded())) }
        )
    }
}
