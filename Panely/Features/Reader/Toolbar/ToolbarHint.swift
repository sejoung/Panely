import SwiftUI

/// The label shown under a hovered toolbar control.
///
/// The toolbar is icon-only, and the system tooltip (`.help`) takes well over
/// a second to appear — long enough that the icons read as unlabeled. These
/// hints show as soon as the pointer lands on a control. The same string is
/// the control's VoiceOver label, so there is one per control instead of two.
struct ToolbarHint: Equatable {
    let id: String
    let text: LocalizedStringKey
}

/// Frame of every hint-bearing control, keyed by hint id, so the toolbar can
/// place the bubble under whichever one is hovered.
struct ToolbarHintAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [String: Anchor<CGRect>],
        nextValue: () -> [String: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct ToolbarHintModifier: ViewModifier {
    let hint: ToolbarHint
    @Binding var hovered: ToolbarHint?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    hovered = hint
                } else if hovered?.id == hint.id {
                    hovered = nil
                }
            }
            .onChange(of: hint) { _, newHint in
                // A control whose label flips under the pointer (pin ↔ unpin,
                // add ↔ remove bookmark) should update the bubble in place.
                if hovered?.id == newHint.id { hovered = newHint }
            }
            .anchorPreference(key: ToolbarHintAnchorKey.self, value: .bounds) {
                [hint.id: $0]
            }
    }
}

extension View {
    /// Attach an instant hover hint to a toolbar control. `id` must be unique
    /// within the toolbar.
    func toolbarHint(
        _ id: String,
        _ text: LocalizedStringKey,
        hovered: Binding<ToolbarHint?>
    ) -> some View {
        modifier(ToolbarHintModifier(hint: ToolbarHint(id: id, text: text), hovered: hovered))
    }
}

/// The bubble itself. Opaque enough to stay legible over any page.
struct ToolbarHintBubble: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(PanelyTypography.caption)
            .foregroundStyle(PanelyColor.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, PanelySpacing.sm)
            .padding(.vertical, PanelySpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(PanelyColor.bgSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(PanelyColor.borderSubtle, lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}
