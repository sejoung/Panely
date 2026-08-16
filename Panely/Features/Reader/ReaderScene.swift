import SwiftUI

/// Top-level reader scene composition: pinned sidebar / viewer / pinned
/// thumbnail strip, plus the hot-edge reveal and overlay sidebar layered on
/// top. Each section is its own `View` under `Scene/` — this file is purely
/// layout + animation wiring + the few pieces of cross-cutting state
/// (hover-driven toolbar visibility, sidebar auto-dismiss timer, keyboard
/// focus).
struct ReaderScene: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @Environment(\.scenePhase) private var scenePhase

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
        .overlay(alignment: .top) {
            ReaderStatusBanner()
                .padding(.top, 42)
        }
        .animation(PanelyMotion.uiReveal, value: viewModel.isLoading)
        .animation(PanelyMotion.uiReveal, value: viewModel.sourceChangedOnDisk)
        .animation(PanelyMotion.uiReveal, value: viewModel.errorMessage)
        .frame(minWidth: 800, minHeight: 600)
        .task {
            await viewModel.refreshContinueReadingAvailability()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel.refreshContinueReadingAvailability() }
        }
        .onDisappear { cancelSidebarDismiss() }
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

private struct ReaderStatusBanner: View {
    @Environment(ReaderViewModel.self) private var viewModel

    var body: some View {
        if let message = viewModel.sourceChangeMessage, viewModel.sourceChangedOnDisk {
            banner(systemImage: "arrow.clockwise.circle", message: message) {
                Button("Reload") {
                    viewModel.reloadCurrentSource()
                }
                Button("Dismiss") {
                    viewModel.clearSourceChangeNotice()
                }
            }
        } else if let message = viewModel.errorMessage, !viewModel.isLoading {
            banner(systemImage: "exclamationmark.triangle", message: message) {
                if viewModel.unavailableRecentItem != nil {
                    Button("Remove from List", role: .destructive) {
                        viewModel.removeUnavailableRecentItem()
                    }
                }
                if viewModel.currentSourceURL != nil {
                    Button("Retry") {
                        viewModel.reloadCurrentSource()
                    }
                }
                Button("Open…") {
                    viewModel.openSource()
                }
            }
        }
    }

    private func banner<Actions: View>(
        systemImage: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
            Text(message)
                .lineLimit(2)
                .font(.system(size: 13, weight: .medium))
            actions()
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, 24)
    }
}

#Preview {
    ReaderScene()
        .environment(ReaderViewModel())
        .environment(ViewerController())
}
