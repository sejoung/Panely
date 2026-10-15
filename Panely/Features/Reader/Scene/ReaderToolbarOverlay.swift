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
            actions: viewModel.toolbarActions(viewerController: viewerController),
            // A popover doesn't inherit the window's `\.locale` — it gets the
            // system one, so its text would stay in the launch language until
            // a restart. Hand it the app's locale explicitly.
            translationPanel: TranslationPanel()
                .environment(viewModel)
                .environment(\.locale, viewModel.localization.locale)
        )
        .padding(PanelySpacing.md)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(PanelyMotion.uiReveal, value: shown)
    }
}
