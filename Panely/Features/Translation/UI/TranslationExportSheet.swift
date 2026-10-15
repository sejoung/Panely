import SwiftUI

/// The choices before exporting a translated book or series: the language,
/// the format, what to do with pages not translated yet, and where to save.
/// Remembered for next time, so a second export is one click.
struct TranslationExportSheet: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    let request: TranslationExportRequest

    @State private var target: TranslationLanguage = .korean
    @State private var format: TranslationExportFormat = .cbz
    @State private var untranslated: UntranslatedPagesPolicy = .translateFirst

    private var locale: Locale { viewModel.localization.locale }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelySpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.isSeries ? "Export Translated Series" : "Export Translated Book")
                    .font(.headline)
                Text(verbatim: request.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if request.isSeries {
                    Text("\(request.books.count) volumes: \(volumeList)")
                        .font(.caption)
                        .foregroundStyle(PanelyColor.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

            Form {
                Picker("Language", selection: $target) {
                    ForEach(targets) { language in
                        Text(verbatim: language.displayName(in: locale)).tag(language)
                    }
                }
                Picker("Format", selection: $format) {
                    Text("CBZ").tag(TranslationExportFormat.cbz)
                    Text("ZIP").tag(TranslationExportFormat.zip)
                    Text("Folder of Images").tag(TranslationExportFormat.folder)
                }
                Picker("Pages Not Translated Yet", selection: $untranslated) {
                    Text("Translate Them First").tag(UntranslatedPagesPolicy.translateFirst)
                    Text("Export As They Are").tag(UntranslatedPagesPolicy.exportAsIs)
                }
                LabeledContent("Save To") {
                    HStack(spacing: PanelySpacing.xs) {
                        if let destination = viewModel.translationExports.destination {
                            Label {
                                Text(verbatim: destination.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "folder")
                            }
                            .help(destination.path)
                        } else {
                            Text("Not Chosen")
                                .foregroundStyle(PanelyColor.textSecondary)
                        }
                        Button("Choose…") {
                            viewModel.chooseTranslationExportDestination()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 196)

            VStack(alignment: .leading, spacing: PanelySpacing.xs) {
                TranslationCaveat(
                    systemImage: "info.circle",
                    text: untranslated == .translateFirst
                        ? "Runs in the background — keep reading. Untranslated pages are translated first, which can take a while. Follow it in Window › Jobs (⌥⌘J)."
                        : "Runs in the background — keep reading. Follow it in Window › Jobs (⌥⌘J)."
                )
                TranslationCaveat(
                    systemImage: "info.circle",
                    text: "Your edits are included and hidden balloons are left out. The original files aren't changed."
                )
                if viewModel.exportNeedsOpenArchive(request) {
                    TranslationCaveat(
                        systemImage: "exclamationmark.triangle",
                        text: "These volumes are inside another archive and only exist while it's open. Keep it open until the export finishes."
                    )
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Export") {
                    viewModel.startTranslationExport(
                        request,
                        options: TranslationExportOptions(target: target, format: format, untranslated: untranslated)
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.translationExports.destination == nil)
                .help(viewModel.translationExports.destination == nil ? Text("Choose where to save first") : Text(verbatim: ""))
            }
        }
        .padding(PanelySpacing.lg)
        .frame(width: 460)
        .onAppear {
            let remembered = viewModel.translationExports.options
            format = remembered?.format ?? .cbz
            untranslated = remembered?.untranslated ?? .translateFirst
            target = targets.contains(request.suggestedTarget) ? request.suggestedTarget : (targets.first ?? .korean)
        }
    }

    /// Every language but the book's own.
    private var targets: [TranslationLanguage] {
        let source = viewModel.exportSourceLanguage(for: request)
        return TranslationLanguage.allCases.filter { $0 != source }
    }

    private var volumeList: String {
        request.books
            .map { $0.hasDirectoryPath ? $0.lastPathComponent : $0.deletingPathExtension().lastPathComponent }
            .joined(separator: ", ")
    }
}
