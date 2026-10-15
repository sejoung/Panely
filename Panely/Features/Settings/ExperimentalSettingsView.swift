import SwiftUI

/// Experimental features — currently the translation assist. Off by default;
/// the toggle is disabled below macOS 26, where Vision can't read vertical
/// text and Apple Translation can't run outside SwiftUI.
@MainActor
struct ExperimentalSettingsView: View {
    let viewModel: ReaderViewModel

    @State private var cacheBytes: UInt64?
    @State private var isClearing = false

    private var locale: Locale { viewModel.localization.locale }

    private var enabled: Binding<Bool> {
        Binding(
            get: { viewModel.translationEnabled },
            set: { viewModel.translationEnabled = $0 }
        )
    }

    private var includeSoundEffects: Binding<Bool> {
        Binding(
            get: { viewModel.translationIncludeSoundEffects },
            set: { viewModel.translationIncludeSoundEffects = $0 }
        )
    }

    private var mode: Binding<TranslationMode> {
        Binding(
            get: { viewModel.translationMode.effective },
            set: { viewModel.translationMode = $0 }
        )
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
                    Toggle("Translate Sound Effects", isOn: includeSoundEffects)
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
