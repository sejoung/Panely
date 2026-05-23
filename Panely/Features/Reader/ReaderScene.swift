import SwiftUI

/// Top-level reader scene composition: pinned sidebar / viewer / pinned
/// thumbnail strip, plus the hot-edge reveal and overlay sidebar layered on
/// top. Each section is its own `View` under `Scene/` — this file is purely
/// layout + animation wiring + the few pieces of cross-cutting state
/// (hover-driven toolbar visibility, sidebar auto-dismiss timer, keyboard
/// focus).
struct ReaderScene: View {
    @Environment(ReaderViewModel.self) private var viewModel

    @State private var toolbarVisible = false
    @State private var sidebarDismissTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    private let sidebarRevealDelayMs = 200
    private let sidebarDismissDelayMs = 300

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                if viewModel.sidebarPinned {
                    SidebarHost(requestFocus: requestFocus)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ViewerArea(
                    toolbarVisible: $toolbarVisible,
                    toolbarShown: toolbarShown,
                    requestFocus: requestFocus,
                    focusBinding: $isFocused
                )
                if viewModel.thumbnailSidebarVisible && viewModel.hasSource {
                    ThumbnailSidebarHost(requestFocus: requestFocus)
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
                SidebarHost(requestFocus: requestFocus)
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

    /// Pinned toolbar overrides hover-driven auto-hide.
    private var toolbarShown: Bool { toolbarVisible || viewModel.toolbarPinned }

    private func requestFocus() {
        isFocused = true
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

#Preview {
    ReaderScene()
        .environment(ReaderViewModel())
        .environment(ViewerController())
}
