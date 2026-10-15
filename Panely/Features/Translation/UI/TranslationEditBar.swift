import SwiftUI

/// Shown over the page while editing balloons (edit mode, ⇧⌘E): what's been
/// changed in this book, the hidden balloons to jump to, reverting the whole
/// book, and the way out. Everything about editing lives here and on the page
/// itself, so the translation panel stays about translating.
struct TranslationEditBar: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @State private var confirmsRevert = false

    var body: some View {
        if viewModel.isEditingTranslations {
            let edits = viewModel.translationEdits
            let edited = edits.editedCount
            HStack(spacing: PanelySpacing.sm) {
                Image(systemName: "pencil.circle.fill")
                Text("Editing Balloons")
                    .font(.system(size: 12, weight: .semibold))

                if confirmsRevert {
                    Text("Revert all \(edited) edited balloons in this book?")
                        .font(.system(size: 12, weight: .medium))
                    Button("Revert All", role: .destructive) {
                        edits.revertAllInBook()
                        confirmsRevert = false
                    }
                    Button("Cancel") {
                        confirmsRevert = false
                    }
                } else {
                    if edited == 0 {
                        Text("Click a balloon to correct or hide it")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    } else {
                        Text("\(edited) edited")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    hiddenMenu
                    if edited > 0 {
                        Button("Revert This Book…") {
                            confirmsRevert = true
                        }
                        .help("Every balloon edited or hidden in this book goes back to the machine translation. Other books keep their edits.")
                    }
                    Button("Done") {
                        viewModel.setEditingTranslations(false)
                    }
                    .help("Back to reading (esc)")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.78), in: Capsule())
            .overlay(Capsule().stroke(PanelyColor.accentPrimary.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            .environment(\.colorScheme, .dark)
            .help("Click a balloon to correct it, or a dashed outline to bring a hidden balloon back.")
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .onChange(of: viewModel.isEditingTranslations) { _, _ in
                confirmsRevert = false
            }
        }
    }

    /// Hidden balloons by page — pick one to go to it (it shows there as a
    /// dashed outline), or bring them all back.
    @ViewBuilder
    private var hiddenMenu: some View {
        let hidden = viewModel.translationHiddenBalloons
        if !hidden.isEmpty {
            Menu {
                ForEach(hidden) { balloon in
                    Button {
                        viewModel.jump(to: balloon.pageIndex)
                    } label: {
                        Text("p. \(balloon.pageIndex + 1)")
                            + Text(verbatim: " · " + (balloon.edit.correctedSource ?? balloon.edit.recognizedSource))
                    }
                }
                Divider()
                Button("Show All Hidden Balloons") {
                    viewModel.translationEdits.showAllHidden()
                }
            } label: {
                Label("\(hidden.count) Hidden", systemImage: "eye.slash")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Go to a hidden balloon, or show them all again")
        }
    }
}
