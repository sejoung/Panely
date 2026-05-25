import SwiftUI

/// Wires `ThumbnailSidebar` to the viewmodel. Mirrors `SidebarHost` — small
/// enough to stay tiny, but kept on its own so the root scene composition
/// reads top-to-bottom without inline closures.
struct ThumbnailSidebarHost: View {
    @Environment(ReaderViewModel.self) private var viewModel
    let requestFocus: () -> Void

    var body: some View {
        ThumbnailSidebar(
            pages: viewModel.source.pages,
            pageDimensions: viewModel.pageDimensions,
            currentPageIndex: viewModel.currentPageIndex,
            onJump: { idx in
                viewModel.jump(to: idx)
                requestFocus()
            },
            onClose: { viewModel.toggleThumbnailSidebar() }
        )
        .id(viewModel.sourceRenderRevision)
    }
}
