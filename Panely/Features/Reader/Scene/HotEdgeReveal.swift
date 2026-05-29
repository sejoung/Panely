import SwiftUI

/// Thin invisible strip along an edge that fires `onReveal` after the cursor
/// has lingered for `delayMs`. Used to summon the auto-hidden sidebar
/// without giving every accidental drift through the screen edge a chance to
/// pop UI in the user's face.
struct HotEdgeReveal: View {
    let delayMs: Int
    let onReveal: () -> Void

    @State private var hoverTask: Task<Void, Never>?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .contentShape(Rectangle())
            Rectangle()
                .fill(hovering ? PanelyColor.accentPrimary.opacity(0.35) : Color.clear)
                .frame(width: 3)
                .allowsHitTesting(false)
        }
        .onHover { isHovering in
            hovering = isHovering
            hoverTask?.cancel()
            if isHovering {
                let delay = delayMs
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled else { return }
                    onReveal()
                }
            }
        }
        .onDisappear {
            // Cancel any pending reveal so `onReveal` can't fire after the
            // view is gone (e.g. window closed mid-hover-delay).
            hoverTask?.cancel()
            hoverTask = nil
        }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}
