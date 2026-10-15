import AppKit
import SwiftUI

/// What a balloon click shows: the translation, the original, and whether
/// that's a machine translation or the reader's edit. Both texts are
/// selectable, so a word can be copied or looked up (Look Up in the context
/// menu) — the original matters as much as the translation for following
/// along.
///
/// In edit mode it's also where a balloon is corrected: rewrite the
/// translation, fix the recognised original and translate it again, hide a
/// balloon OCR made up out of artwork, or revert. Each change goes out through
/// `onEdit` and closes the popover; the page redraws with it. While reading it
/// stays a plain look-up, with one link into edit mode.
///
/// Hosted in an `NSPopover` outside the main SwiftUI tree, so it doesn't
/// inherit the app's `\.locale`; its UI strings are resolved through
/// `Bundle.localized` instead.
struct TranslationBubblePopover: View {
    let source: String
    /// `nil` while the translation is still on its way.
    let translation: String?
    /// The same balloon in the book's other translated languages.
    var alternates: [TranslationLanguage: String] = [:]
    var edit: BubbleEditState?
    /// Edit mode: the editing controls show. Reading: an "Edit…" link.
    var isEditing = false
    /// `nil` hides the editing controls (previews).
    var onEdit: ((TranslationEditChange) -> Void)?
    /// While editing the popover mustn't close on a stray click outside.
    var onEditingChanged: (Bool) -> Void = { _ in }

    private enum Mode {
        case viewing
        case editingTranslation
        case editingSource
    }

    @State private var mode = Mode.viewing
    @State private var draft = ""

    private var shownSource: String { edit?.correctedSource ?? source }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelySpacing.sm) {
            if mode == .editingTranslation {
                editor(save: L("Save")) { onEdit?(.setTranslation(draft)) }
            } else {
                translationText
            }

            if !alternates.isEmpty {
                let locale = AppLocalization.shared.locale
                ForEach(alternates.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { language in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: language.displayName(in: locale))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PanelyColor.textSecondary)
                        Text(verbatim: alternates[language] ?? "")
                            .font(.system(size: 13))
                            .foregroundStyle(PanelyColor.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            if mode == .editingSource {
                editor(save: L("Translate Again")) { onEdit?(.correctSource(draft)) }
            } else {
                sourceText
            }

            if mode == .viewing {
                footer
                if let onEdit {
                    if isEditing {
                        actions
                    } else {
                        HStack {
                            Spacer(minLength: 0)
                            Button {
                                onEdit(.enterEditMode)
                            } label: {
                                Label(L("Edit…"), systemImage: "pencil")
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help(L("Switch to edit mode to correct or hide balloons (⇧⌘E)"))
                        }
                    }
                }
            }
        }
        .padding(PanelySpacing.md)
        .frame(width: 300, alignment: .leading)
        .onChange(of: mode) { _, mode in
            onEditingChanged(mode != .viewing)
        }
    }

    // MARK: - Viewing

    @ViewBuilder
    private var translationText: some View {
        if let translation {
            Text(verbatim: translation)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PanelyColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: PanelySpacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: L("Translating…"))
                    .foregroundStyle(PanelyColor.textSecondary)
            }
        }
    }

    private var sourceText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: shownSource)
                .font(.system(size: 14))
                .foregroundStyle(PanelyColor.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if edit?.correctedSource != nil {
                // What OCR read, so a wrong correction can be spotted.
                Text(verbatim: L("Recognized as: \(source)"))
                    .font(.caption)
                    .foregroundStyle(PanelyColor.textSecondary.opacity(0.8))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Where the shown translation comes from and, once the balloon is
    /// edited, a clear way back — next to the label saying it's edited.
    private var footer: some View {
        VStack(alignment: .leading, spacing: PanelySpacing.xs) {
            Label {
                Text(verbatim: footerText)
            } icon: {
                Image(systemName: edit == nil ? "character.bubble" : "pencil")
            }
            .font(.caption)
            .foregroundStyle(edit == nil ? PanelyColor.textSecondary.opacity(0.8) : PanelyColor.accentPrimary)
            .fixedSize(horizontal: false, vertical: true)

            if isEditing, let onEdit, let edit {
                HStack(spacing: PanelySpacing.xs) {
                    Spacer(minLength: 0)
                    if edit.needsRetranslation {
                        Button {
                            onEdit(.retranslate)
                        } label: {
                            Label(L("Translate Again"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    revertControl(edit, onEdit: onEdit)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// One button when one thing was changed; a menu when both the
    /// translation and the original were.
    @ViewBuilder
    private func revertControl(_ edit: BubbleEditState, onEdit: @escaping (TranslationEditChange) -> Void) -> some View {
        let label = Label(L("Revert"), systemImage: "arrow.uturn.backward")
        if edit.translationIsReaders, edit.correctedSource != nil {
            Menu {
                Button(L("Use Machine Translation")) { onEdit(.revertTranslation) }
                Button(L("Restore Original")) { onEdit(.revertSource) }
                Divider()
                Button(L("Revert Both")) { onEdit(.revertAll) }
            } label: {
                label
            }
            .menuStyle(.button)
            .fixedSize()
            .help(L("Go back to the machine translation, the recognized original, or both"))
        } else if edit.translationIsReaders {
            Button { onEdit(.revertTranslation) } label: { label }
                .help(L("Use the machine translation again"))
        } else if edit.correctedSource != nil {
            Button { onEdit(.revertSource) } label: { label }
                .help(L("Restore the recognized original and its machine translation"))
        }
    }

    private var footerText: String {
        guard let edit else { return L("Machine translation") }
        if edit.translationIsReaders { return L("Your translation") }
        if edit.needsRetranslation { return L("Original corrected — not translated again yet") }
        return L("Machine translation of your corrected original")
    }

    private var actions: some View {
        HStack(spacing: PanelySpacing.xs) {
            Button {
                startEditing(.editingTranslation, text: translation ?? "")
            } label: {
                Label(L("Edit"), systemImage: "pencil")
            }
            .disabled(translation == nil)
            .help(L("Rewrite this translation"))
            Button {
                startEditing(.editingSource, text: shownSource)
            } label: {
                Label(L("Fix Original"), systemImage: "text.cursor")
            }
            .help(L("Correct the recognized text and translate it again"))
            Spacer(minLength: 0)
            Button {
                onEdit?(.hide)
            } label: {
                Label(L("Hide"), systemImage: "eye.slash")
            }
            .help(L("Hide this balloon — for text that isn't really there. Show it again from the translation panel."))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Editing

    private func editor(save title: String, onSave: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: PanelySpacing.xs) {
            BalloonTextEditor(text: $draft, onSubmit: onSave, onCancel: { mode = .viewing })
                .frame(height: 96)
            HStack(spacing: PanelySpacing.xs) {
                Text(verbatim: L("⇧↩ for a new line"))
                    .font(.caption2)
                    .foregroundStyle(PanelyColor.textSecondary)
                Spacer(minLength: 0)
                Button(L("Cancel")) { mode = .viewing }
                    .keyboardShortcut(.cancelAction)
                Button(title, action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
    }

    private func startEditing(_ newMode: Mode, text: String) {
        draft = text
        mode = newMode
    }

    private func L(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .localized)
    }
}

/// The popover's text box. A plain `NSTextView` rather than a SwiftUI text
/// field so the keys are ours: Return saves, Esc cancels, and a line break is
/// Shift-Return — or Option- or Control-Return, the text system's own, for
/// whoever has Shift-Return taken (and the other way round).
private struct BalloonTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.string = text
        textView.selectAll(nil)
        // Type straight away; the popover's window may not be up yet.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BalloonTextEditor

        init(_ parent: BalloonTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift-Return arrives as a plain newline command.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                } else {
                    parent.text = textView.string
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                // Option-/Control-Return (insertNewlineIgnoringFieldEditor,
                // insertLineBreak) break the line as usual.
                return false
            }
        }
    }
}

#Preview {
    TranslationBubblePopover(
        source: "あの方のお導きに誤りなどあるはずがございません",
        translation: "그 분의 인도에 오류 등이 있을 리가 없습니다.",
        isEditing: true,
        onEdit: { _ in }
    )
    .preferredColorScheme(.dark)
}
