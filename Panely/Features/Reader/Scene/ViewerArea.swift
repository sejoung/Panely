import SwiftUI

/// The viewer pane: image container, key/hover handlers, and all
/// overlays anchored to the viewer (toolbar, slider, volume cards).
/// Owns nothing — the parent passes a hover-binding for toolbar reveal and
/// a `requestFocus` callback so child actions can return keyboard focus to
/// the viewer.
struct ViewerArea: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @Environment(ViewerController.self) private var viewerController
    @Binding var toolbarVisible: Bool
    let toolbarShown: Bool
    let requestFocus: () -> Void
    let focusBinding: FocusState<Bool>.Binding

    private let revealZoneHeight: CGFloat = 80

    var body: some View {
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
                TitleBarPassthrough(systemSettings: viewModel.dependencies.systemSettings)
                    .frame(height: 28)
                    .ignoresSafeArea(edges: .top)
            }
            .overlay(alignment: .top) { ReaderToolbarOverlay(shown: toolbarShown) }
            .overlay(alignment: .bottom) { ReaderSliderOverlay(shown: toolbarShown) }
            .overlay(alignment: .bottom) { EndOfVolumeCardOverlay(requestFocus: requestFocus) }
            .overlay(alignment: .top) { PreviousVolumeCardOverlay(requestFocus: requestFocus) }
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
            .focused(focusBinding)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) {
                viewModel.effectiveDirection.isRTL ? viewModel.advanceForward() : viewModel.goBackward()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                viewModel.effectiveDirection.isRTL ? viewModel.goBackward() : viewModel.advanceForward()
                return .handled
            }
            .onKeyPress(.space) {
                viewModel.advanceForward()
                return .handled
            }
            .onKeyPress(.escape) {
                if viewModel.sidebarOverlayVisible {
                    viewModel.dismissSidebarOverlay()
                    return .handled
                }
                return .ignored
            }
            .onAppear { requestFocus() }
            .onChange(of: viewModel.currentSourceURL) { _, _ in
                requestFocus()
            }
        }
    }

    /// Identity changes ONLY when the source changes — that's what triggers
    /// force-reset of magnification (a new book legitimately resets fit).
    /// Layout-driven stack rebuilds happen automatically inside
    /// ImageStackView.setImages (count + axis comparison), no need to encode
    /// the layout here. Including it would otherwise override the lock and
    /// defeat user-zoom preservation.
    private var viewerIdentity: String {
        viewModel.currentSourceURL?.path ?? ""
    }
}
