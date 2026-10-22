import SwiftUI

/// Experimental features — currently the translation assist. Off by default;
/// the toggle is disabled below macOS 26, where Vision can't read vertical
/// text.
@MainActor
struct ExperimentalSettingsView: View {
    let viewModel: ReaderViewModel

    @State private var cacheBytes: UInt64?
    @State private var isClearing = false
    @State private var editedPageCount: Int?
    @State private var isDeletingEdits = false
    @State private var confirmsDeletingEdits = false
    @State private var confirmsDeletingModel = false

    private var locale: Locale { viewModel.localization.locale }

    private var enabled: Binding<Bool> {
        Binding(
            get: { viewModel.translationEnabled },
            set: { viewModel.translationEnabled = $0 }
        )
    }

    private var model: TranslationModelStore { viewModel.translationManager.model }

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
                    Text("The default language is what new series are shown in. Each series can be shown in another language, and each book's own language is detected the first time it's translated — both from the translation button in the toolbar, remembered per series.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Translation Model") {
                    LabeledContent(model.model.displayName) {
                        switch model.state {
                        case .installed:
                            Text("Downloaded · \(TranslationModelSize.text(model.model.bytes))")
                        case .notInstalled, .failed:
                            Text("Not downloaded")
                        case .downloading, .verifying:
                            EmptyView()
                        }
                    }
                    if model.isDownloading {
                        TranslationModelDownloadProgress(model: model)
                    } else if model.isInstalled {
                        Button("Delete Translation Model…", role: .destructive) {
                            confirmsDeletingModel = true
                        }
                        .confirmationDialog("Delete the translation model?", isPresented: $confirmsDeletingModel) {
                            Button("Delete Model", role: .destructive) {
                                Task { await deleteModel() }
                            }
                        } message: {
                            Text("Books already translated stay translated. Translating anything else downloads the model again (\(TranslationModelSize.text(model.model.bytes))).")
                        }
                    } else {
                        Button("Download (\(TranslationModelSize.text(model.model.bytes)))") {
                            model.download()
                        }
                    }
                    if case let .failed(reason) = model.state {
                        Text("The download stopped: \(reason)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("One model translates every language pair on your Mac. It reads each page's balloons together with the lines before them, so names and each speaker's speech level — polite or casual — carry over. Downloaded once from Hugging Face; nothing you read leaves your Mac. Uses about 3.5 GB of memory while translating.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Gemma 4 by Google (Apache License 2.0), run with llama.cpp (MIT License).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            model.refresh()
            await refreshCacheSize()
            await refreshEditedPageCount()
        }
    }

    private func deleteModel() async {
        await viewModel.translationManager.deleteModel()
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
