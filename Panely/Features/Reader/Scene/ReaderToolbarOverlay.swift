import SwiftUI

/// The floating toolbar shown along the top edge of the viewer. State and
/// actions come from the viewmodel; this overlay only handles show/hide
/// opacity gating.
struct ReaderToolbarOverlay: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @Environment(ViewerController.self) private var viewerController
    let shown: Bool

    var body: some View {
        PanelyToolbar(
            state: viewModel.toolbarState(isAtFit: viewerController.isAtFit),
            actions: viewModel.toolbarActions(viewerController: viewerController)
        )
        .padding(PanelySpacing.md)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(PanelyMotion.uiReveal, value: shown)
    }
}
