import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Improving translations through the reader's own AI chat, by file: ① save
/// the book's balloons as a text file; ② attach it in ChatGPT, Claude,
/// Gemini… with the prompt shown here; ③ open the text file the chat sends
/// back (or paste the reply, when it answered in the chat). A file carries a
/// whole book where pasted text can be cut short, and the prompt asks for
/// every balloon back, so any the chat dropped are named. The reply's
/// translations become the reader's own, and can be undone in one go. Pages
/// can be narrowed for a chat that can't take a whole book.
struct AIChatSheet: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    let request: AIChatRequest

    private enum Extent: Hashable {
        case book
        case pages
    }

    @State private var extent: Extent = .book
    @State private var firstPage = 1
    @State private var lastPage = 1
    @State private var savedFile: String?
    @State private var promptCopied = false
    @State private var result: AIChatExchange.Changes?
    @State private var problem: LocalizedStringKey?

    private var pageCount: Int { max(1, viewModel.source.pages.count) }

    private var scope: AIChatScope {
        switch extent {
        case .pages: .pages((min(firstPage, lastPage) - 1)...(max(firstPage, lastPage) - 1))
        case .book: .book
        }
    }

    private var balloons: Int { viewModel.aiChatLines(for: scope).count }

    /// The file's name as it'll be saved, for the prompt to refer to.
    private var fileName: String {
        savedFile ?? viewModel.aiChatFileName(for: scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelySpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Improve with an AI Chat")
                    .font(.headline)
                Text("A chat that reads the whole book can fix what translating balloon by balloon misses: who's speaking, how they speak, names. Use the one you already have — ChatGPT, Claude, Gemini or another.")
                    .font(.callout)
                    .foregroundStyle(PanelyColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                Picker("Pages", selection: $extent) {
                    Text("Whole Book").tag(Extent.book)
                    Text("Choose Pages").tag(Extent.pages)
                }
                if extent == .pages {
                    Stepper(value: $firstPage, in: 1...pageCount) {
                        Text("From page \(firstPage)")
                    }
                    Stepper(value: $lastPage, in: 1...pageCount) {
                        Text("To page \(lastPage)")
                    }
                }
                LabeledContent("Balloons") {
                    Text(verbatim: "\(balloons)")
                        .monospacedDigit()
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: extent == .pages ? 190 : 120)
            .onChange(of: scope) { _, _ in
                savedFile = nil
                promptCopied = false
            }

            step(1, detail: savedFile.map { "Saved “\($0)”. Attach it to a new chat." } ?? "The balloons, a line each: [id] original → translation.") {
                Button {
                    save()
                } label: {
                    Label("Save as Text File…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(balloons == 0)
            }

            step(2, detail: promptCopied ? "Copied. Paste it into the chat with the file attached." : "Paste this into the chat along with the file. Change it if you like.") {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        Text(verbatim: viewModel.aiChatPromptText(fileName: fileName, balloons: balloons))
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 120)
                    .background(PanelyColor.bgTertiary, in: RoundedRectangle(cornerRadius: 6))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(viewModel.aiChatPromptText(fileName: fileName, balloons: balloons), forType: .string)
                        promptCopied = true
                    } label: {
                        Label("Copy Prompt", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
            }

            step(3, detail: resultText) {
                HStack {
                    Button {
                        open()
                    } label: {
                        Label("Open the Reply…", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    // A chat that answered in the conversation instead of a file.
                    Button {
                        paste()
                    } label: {
                        Label("Paste the Reply", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    if viewModel.aiChatUndo != nil {
                        Button("Undo") {
                            viewModel.undoAIChatReply()
                            result = nil
                        }
                        .help("Put back the translations this reply changed")
                    }
                }
            }

            TranslationCaveat(
                systemImage: "lock",
                text: "Your text leaves your Mac only when you give it to a chat. Changed balloons count as your edits: each can go back to the machine translation."
            )

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(PanelySpacing.lg)
        .frame(width: 520)
        .onAppear {
            // Choosing pages starts from the ones on screen.
            if case let .pages(range) = viewModel.aiChatCurrentPages {
                firstPage = range.lowerBound + 1
                lastPage = range.upperBound + 1
            }
            if case let .pages(range) = request.scope {
                firstPage = range.lowerBound + 1
                lastPage = range.upperBound + 1
                extent = .pages
            }
        }
    }

    private var resultText: LocalizedStringKey {
        if let problem { return problem }
        guard let result else { return "Open the text file the chat sent back, or paste its reply if it answered in the chat. Changed translations replace the current ones." }
        let missing = result.missing.prefix(6).joined(separator: ", ") + (result.missing.count > 6 ? " …" : "")
        if result.missing.isEmpty {
            return "All \(result.returned) balloons came back: \(result.updates.count) changed, \(result.unchanged) already right."
        }
        return "\(result.returned) balloons came back: \(result.updates.count) changed, \(result.unchanged) already right. Missing \(result.missing.count): \(missing) — ask the chat for those, or choose fewer pages."
    }

    private func step<Content: View>(_ number: Int, detail: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: PanelySpacing.sm) {
            Text(verbatim: "\(number)")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 22, height: 22)
                .background(PanelyColor.accentPrimary.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                content()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PanelyColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() {
        let file = viewModel.aiChatFile(for: scope)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = file.fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            savedFile = url.lastPathComponent
            problem = nil
            result = nil
        } catch {
            problem = "Couldn't save the file: \(error.localizedDescription)"
        }
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let reply = try? String(contentsOf: url, encoding: .utf8) else {
            problem = "Couldn't read that file as text."
            return
        }
        take(reply)
    }

    private func paste() {
        guard let reply = NSPasteboard.general.string(forType: .string), !reply.isEmpty else {
            problem = "The clipboard has no text. Copy the chat's reply first."
            return
        }
        take(reply)
    }

    private func take(_ reply: String) {
        let changes = viewModel.applyAIChatReply(reply)
        if changes.returned == 0 {
            problem = "No balloon lines like “[p12-3] …” in it. Use the chat's whole reply."
            result = nil
        } else {
            problem = nil
            result = changes
        }
    }
}
