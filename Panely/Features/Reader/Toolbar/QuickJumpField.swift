import SwiftUI

/// Inline, click-to-edit page counter. Displayed as `12 / 120` (or
/// `12-13 / 120` in double-page mode). Clicking the leading number turns it
/// into a focused `TextField`; Enter commits, Escape cancels. A menu-driven
/// `⌘G` prompt (in `PanelyApp`) provides the same functionality as a modal
/// alert for users who prefer the keyboard.
struct QuickJumpField: View {
    let currentPage: Int      // 1-indexed start of the currently visible span
    let rangeEndPage: Int     // 1-indexed end of the span (== currentPage when single-page)
    let totalPages: Int
    let onJump: (Int) -> Void // 1-indexed

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            numberView
            Text(" / \(totalPages)")
        }
        .font(PanelyTypography.caption)
        .foregroundStyle(PanelyColor.textSecondary)
    }

    @ViewBuilder
    private var numberView: some View {
        if editing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(PanelyTypography.caption)
                .foregroundStyle(PanelyColor.textPrimary)
                .focused($focused)
                .frame(width: fieldWidth)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(PanelyColor.bgTertiary)
                )
                .onSubmit(commit)
                .onExitCommand(perform: endEditing)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { endEditing() }
                }
        } else {
            Text(displayText)
                .contentShape(Rectangle())
                .onTapGesture(perform: beginEditing)
                .help("Click to jump to a page (⌘G)")
        }
    }

    private var displayText: String {
        currentPage == rangeEndPage ? "\(currentPage)" : "\(currentPage)-\(rangeEndPage)"
    }

    private var fieldWidth: CGFloat {
        // Room for the largest page number plus a bit of padding.
        max(32, CGFloat(String(totalPages).count) * 9 + 10)
    }

    private func beginEditing() {
        draft = "\(currentPage)"
        editing = true
        // Focus must be requested after the TextField is in the hierarchy.
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        defer { endEditing() }
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard let parsed = Int(trimmed) else { return }
        let clamped = min(max(parsed, 1), totalPages)
        onJump(clamped)
    }

    private func endEditing() {
        editing = false
        focused = false
        draft = ""
    }
}

#Preview {
    QuickJumpField(
        currentPage: 12,
        rangeEndPage: 13,
        totalPages: 120,
        onJump: { _ in }
    )
    .padding(PanelySpacing.lg)
    .background(PanelyColor.bgSecondary)
}
