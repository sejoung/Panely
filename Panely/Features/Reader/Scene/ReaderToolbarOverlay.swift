import SwiftUI

/// The floating toolbar shown along the top edge of the viewer. State and
/// actions come from the viewmodel; this overlay only handles show/hide
/// opacity gating.
struct ReaderToolbarOverlay: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @Environment(ViewerController.self) private var viewerController
    let shown: Bool

    /// While hidden the toolbar keeps its last state instead of reading the
    /// current one, so a page turn (or a slider tick) doesn't invalidate this
    /// body, and with it every toolbar control, for a toolbar nobody can see.
    /// `shown` turning true re-reads everything. Stays mounted while hidden,
    /// though: that's what keeps its fade and an open translation popover.
    @State private var lastState = LastState()

    private final class LastState {
        var value: PanelyToolbarState?
    }

    private var state: PanelyToolbarState {
        if !shown, let state = lastState.value { return state }
        let state = viewModel.toolbarState(isAtFit: viewerController.isAtFit)
        lastState.value = state
        return state
    }

    var body: some View {
        PanelyToolbar(
            state: state,
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
