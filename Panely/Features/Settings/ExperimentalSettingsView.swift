import SwiftUI

/// Experimental features — currently the translation assist. Off by default;
/// the toggle is disabled below macOS 26, where Vision can't read vertical
/// text and Apple Translation can't run outside SwiftUI.
@MainActor
struct ExperimentalSettingsView: View {
    let viewModel: ReaderViewModel

    @State private var cacheBytes: UInt64?
    @State private var isClearing = false
    @State private var editedPageCount: Int?
    @State private var isDeletingEdits = false
    @State private var confirmsDeletingEdits = false

    private var locale: Locale { viewModel.localization.locale }

    private var enabled: Binding<Bool> {
        Binding(
            get: { viewModel.translationEnabled },
            set: { viewModel.translationEnabled = $0 }
        )
    }

    private var matchesSpeechLevel: Binding<Bool> {
        Binding(
            get: { viewModel.translationMatchesSpeechLevel },
            set: { viewModel.translationMatchesSpeechLevel = $0 }
        )
    }

    private var mode: Binding<TranslationMode> {
        Binding(
            get: { viewModel.translationMode.effective },
            set: { viewModel.translationMode = $0 }
        )
    }

    /// What matching does, or why it can't run here.
    private var speechLevelNote: LocalizedStringKey {
        switch SpeechLevelAvailability.current {
        case .available:
            "Japanese ↔ Korean: Apple Translation tends to make every line polite. Apple Intelligence rewrites the endings to match the original — casual stays casual — on your Mac. A rewrite is used only if it keeps the same words."
        case .appleIntelligenceOff:
            "Needs Apple Intelligence — turn it on in System Settings › Apple Intelligence & Siri."
        case .notEligible:
            "Needs Apple Intelligence, which this Mac doesn't support."
        case .notReady:
            "Apple Intelligence is still getting ready. Try again in a little while."
        case .unsupportedSystem:
            "Requires macOS 26 or later."
        }
    }

    var body: some View {
        Form {
            Section("Experimental") {
                Toggle("Translation Assist", isOn: enabled)
                    .disabled(!TranslationController.isSupportedOnThisMac)
                Text("Reads the text in speech balloons and shows an on-device machine translation over the page. It's meant to help you follow the story, not to replace a real translation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !TranslationController.isSupportedOnThisMac {
                    Text("Requires macOS 26 or later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.translationFeatureAvailable {
                Section("Translation") {
                    TranslationTargetPicker(viewModel: viewModel)
                    Picker("Translation Mode", selection: mode) {
                        Text("Fast").tag(TranslationMode.fast)
                        Text("Accurate").tag(TranslationMode.accurate)
                    }
                    .disabled(!TranslationMode.isFastAvailable)
                    Text(TranslationMode.isFastAvailable
                        ? "Fast translates a volume in about a minute. Accurate reads idioms and nuance better but takes about 20 times as long. Each mode downloads its own language packs."
                        : "Fast translation requires macOS 26.4 or later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Language packs are downloaded from the translation panel the first time a book is translated. Manage downloaded packs in System Settings › General › Language & Region › Translation Languages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Match Speech Level", isOn: matchesSpeechLevel)
                        .disabled(SpeechLevelAvailability.current != .available)
                    Text(speechLevelNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("The default language is what new series are shown in. Each series can be shown in another language, and each book's own language is detected the first time it's translated — both from the translation button in the toolbar, remembered per series.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let downloading = viewModel.translationManager.languagePacks.downloading
                if !downloading.isEmpty {
                    Section("Language Packs") {
                        ForEach(downloading, id: \.self) { pack in
                            LabeledContent {
                                LanguagePackDownloadingLabel()
                            } label: {
                                Text(verbatim: "\(pack.source.displayName(in: locale)) → \(pack.target.displayName(in: locale))")
                            }
                        }
                        Text(LanguagePackDownloadingLabel.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Your Edits") {
                    LabeledContent("Edited pages") {
                        if let editedPageCount, !isDeletingEdits {
                            Text(verbatim: "\(editedPageCount)")
                                .monospacedDigit()
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    Text("Translations you rewrote, originals you corrected and balloons you hid. They're kept apart from the cache, so clearing it or translating again keeps them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Delete All Edits…", role: .destructive) {
                        confirmsDeletingEdits = true
                    }
                    .disabled(isDeletingEdits || (editedPageCount ?? 0) == 0)
                    .confirmationDialog("Delete all your translation edits?", isPresented: $confirmsDeletingEdits) {
                        Button("Delete All Edits", role: .destructive) {
                            deleteEdits()
                        }
                    } message: {
                        Text("Rewritten translations, corrected originals and hidden balloons go back to the machine translation in every book. This can't be undone.")
                    }
                }

                Section("Translation Cache") {
                    LabeledContent("Cached translations") {
                        if let cacheBytes, !isClearing {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .binary))
                                .monospacedDigit()
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    Button("Clear Translation Cache", role: .destructive) {
                        clearCache()
                    }
                    .disabled(isClearing || (cacheBytes ?? 0) == 0)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 12)
        .task(id: viewModel.translationFeatureAvailable) {
            await refreshCacheSize()
            await refreshEditedPageCount()
        }
    }

    private func refreshEditedPageCount() async {
        let store = viewModel.translationEdits.store
        editedPageCount = await Task.detached(priority: .utility) { store.pageCount() }.value
    }

    private func deleteEdits() {
        isDeletingEdits = true
        Task {
            await viewModel.translationEdits.removeAll()
            await refreshEditedPageCount()
            isDeletingEdits = false
        }
    }

    private func refreshCacheSize() async {
        let store = viewModel.translation.store
        cacheBytes = await Task.detached(priority: .utility) { store.sizeBytes() }.value
    }

    private func clearCache() {
        isClearing = true
        Task {
            _ = await viewModel.translationManager.clearCache()
            await refreshCacheSize()
            isClearing = false
        }
    }
}

#Preview {
    ExperimentalSettingsView(viewModel: ReaderViewModel())
        .preferredColorScheme(.dark)
}
