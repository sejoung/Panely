import SwiftUI

/// The translation panel: translating the open book, nothing else. Opened
/// from the toolbar's ▾ menu (or the button itself before there's anything
/// to show).
///
/// Top to bottom, by how often each is needed:
/// - **What to do next** — one big button (download the model, translate,
///   pause, resume) and one status line (progress, the model).
/// - **View** — the original or one of the book's languages; other languages
///   start, pause or stop from their `⋯` menu.
/// - **This book & series** — collapsed: the book's language, auto-translate,
///   translating the whole series, and the limits that apply.
/// - **Edit Balloons** — into edit mode, where correcting happens on the page.
///
/// Elsewhere on purpose: on/off and switching languages (toolbar, ⇧⌘T),
/// running progress (the pill over the page), other books' jobs and exports
/// (their own pill, opening Window › Jobs), editing (edit mode's bar) and
/// app-wide choices (Settings, ⚙︎). Exporting the book is in the toolbar's
/// language menu; the whole series is here, beside translating it.
struct TranslationPanel: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var showsBookSettings = false
    @State private var confirmsTranslatingAgain = false

    private var locale: Locale { viewModel.localization.locale }

    private var sourceBinding: Binding<TranslationLanguage?> {
        Binding(
            get: { viewModel.translationSourceLanguage },
            set: { viewModel.translationSourceLanguage = $0 }
        )
    }

    private var autoBinding: Binding<Bool> {
        Binding(
            get: { viewModel.translationAutoTranslatesSeries },
            set: { viewModel.translationAutoTranslatesSeries = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelySpacing.md) {
            header

            if viewModel.translationSourceLanguage != viewModel.translationDisplayLanguage {
                TranslationPrimaryAction()
            }

            VStack(alignment: .leading, spacing: PanelySpacing.xs) {
                Text("View")
                    .font(.subheadline.weight(.semibold))
                originalRow
                ForEach(viewModel.translationLanguagesForBook, id: \.target) { controller in
                    TranslationLanguageRow(controller: controller)
                }
                addLanguageMenu
            }

            DisclosureGroup(isExpanded: $showsBookSettings) {
                bookSettings
                    .padding(.top, PanelySpacing.xs)
            } label: {
                HStack(spacing: PanelySpacing.xs) {
                    Text("This Book & Series")
                        .font(.subheadline.weight(.semibold))
                    if let source = viewModel.translationSourceLanguage {
                        Text(verbatim: "· " + source.displayName(in: locale))
                            .font(.caption)
                            .foregroundStyle(PanelyColor.textSecondary)
                    }
                    if hasBookCaveat {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showsBookSettings.toggle() }
            }

            if viewModel.showsTranslationBalloonTip {
                HStack(alignment: .top, spacing: PanelySpacing.xs) {
                    TranslationCaveat(
                        systemImage: "lightbulb",
                        text: "Click a balloon to see the original next to its translations."
                    )
                    Spacer(minLength: 0)
                    Button {
                        viewModel.showsTranslationBalloonTip = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PanelyColor.textSecondary)
                    .help("Don't Show Again")
                }
            }

            Divider()

            Button {
                viewModel.setEditingTranslations(true)
                dismiss()
            } label: {
                Label("Edit Balloons", systemImage: "pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canEditTranslations)
            .help("Correct translations, fix misread originals and hide balloons, right on the page (⇧⌘E)")
        }
        .padding(PanelySpacing.md)
        .frame(width: 340, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: PanelySpacing.xs) {
            Text("Translation")
                .font(.headline)
            Text("Experimental")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(PanelyColor.bgTertiary, in: Capsule())
                .foregroundStyle(PanelyColor.textSecondary)
            Spacer(minLength: 0)
            Button {
                viewModel.settingsTab = .experimental
                dismiss()
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(PanelyColor.textSecondary)
            .help("Translation Settings")
        }
    }

    // MARK: - This book & series

    private var hasBookCaveat: Bool {
        viewModel.currentBookLivesInTemporaryFolder || !viewModel.seriesTranslationSkipped.isEmpty
    }

    private var bookSettings: some View {
        VStack(alignment: .leading, spacing: PanelySpacing.sm) {
            sourceRow
            Toggle("Translate This Series Automatically", isOn: autoBinding)

            let volumes = viewModel.translatableSeriesVolumes
            if !volumes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Button("Translate Entire Series (\(volumes.count + 1) Volumes)") {
                        Task { await viewModel.translateEntireSeries() }
                    }
                    .help("Translates this book first, then the other volumes of the series in the background.")
                    // Name what will be queued, so an unexpected match shows before it runs.
                    Text("Also queues: \(volumeList(volumes))")
                        .font(.caption)
                        .foregroundStyle(PanelyColor.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Button("Export Translated Series…") {
                        dismiss()
                        viewModel.requestExportOfCurrentSeries()
                    }
                    .padding(.top, PanelySpacing.xs)
                    .help("Saves a copy of every volume with its translation painted in, as CBZ or ZIP files or folders of images. Volumes not translated yet are translated first.")
                }
            }

            if viewModel.canImproveWithAIChat {
                Button("Improve with an AI Chat…") {
                    dismiss()
                    viewModel.requestAIChat()
                }
                .help("Save the book's balloons as a text file for ChatGPT, Claude or another chat to improve in context, then open its reply.")
            }

            if viewModel.canTranslateAgain {
                Button("Translate This Book Again…") {
                    confirmsTranslatingAgain = true
                }
                .help("Read and translate every page again, the current way. Your edits stay.")
                .confirmationDialog("Translate this book again?", isPresented: $confirmsTranslatingAgain) {
                    Button("Translate Again") {
                        viewModel.translateBookAgain()
                    }
                } message: {
                    Text("Every page is read and translated again, the way Panely does it now — balloons a page split in two are joined. It takes as long as the first time. Your edits stay, but one on a balloon that's now found differently may no longer apply.")
                }
            }

            if !viewModel.seriesTranslationSkipped.isEmpty {
                TranslationCaveat(
                    systemImage: "exclamationmark.triangle",
                    text: "Skipped \(viewModel.seriesTranslationSkipped.count) volumes that are archives inside archives — open each one to translate it: \(viewModel.seriesTranslationSkipped.joined(separator: ", "))"
                )
            }

            if viewModel.currentBookLivesInTemporaryFolder {
                TranslationCaveat(
                    systemImage: "exclamationmark.triangle",
                    text: "This book is an archive inside an archive. Its translation pauses when you open another book and continues when you come back."
                )
            }
        }
    }

    private var sourceRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: PanelySpacing.xs) {
                Text("Book's Language")
                Spacer()
                Picker("Book's Language", selection: sourceBinding) {
                    if viewModel.translationSourceLanguage == nil {
                        Text("Detect Automatically").tag(TranslationLanguage?.none)
                    }
                    ForEach(TranslationLanguage.allCases) { language in
                        Text(verbatim: language.displayName(in: locale))
                            .tag(TranslationLanguage?.some(language))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text(
                viewModel.translationSourceLanguage == nil
                    ? "The book's language is detected when translation starts."
                    : "Remembered for this series."
            )
            .font(.caption)
            .foregroundStyle(PanelyColor.textSecondary)
        }
    }

    // MARK: - View

    /// "Original" — translation off (⇧⌘T toggles back to the language).
    private var originalRow: some View {
        let isSelected = !viewModel.translationIsShowing
        return Button {
            viewModel.showOriginal()
        } label: {
            HStack(spacing: PanelySpacing.sm) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? PanelyColor.accentPrimary : PanelyColor.textSecondary)
                Text("Original (Translation Off)")
                Spacer()
                Text(verbatim: "⇧⌘T")
                    .font(.caption)
                    .foregroundStyle(PanelyColor.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Languages the book isn't listed in yet: picking one shows it and
    /// starts translating into it.
    @ViewBuilder
    private var addLanguageMenu: some View {
        let listed = Set(viewModel.translationLanguagesForBook.map(\.target))
        let source = viewModel.translationSourceLanguage
        let available = TranslationLanguage.allCases.filter { !listed.contains($0) && $0 != source }
        if !available.isEmpty {
            Menu("Translate into Another Language") {
                ForEach(available) { language in
                    Button(language.displayName(in: locale)) {
                        viewModel.showTranslation(in: language)
                        viewModel.startTranslating(into: language)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func volumeList(_ volumes: [URL]) -> String {
        let names = volumes.map { $0.deletingPathExtension().lastPathComponent }
        let shown = names.prefix(4).joined(separator: ", ")
        return names.count > 4 ? shown + " …" : shown
    }
}

/// One of the open book's languages: pick it to show it. Its count shows how
/// far along it is; a language other than the shown one is started, paused or
/// stopped from its `⋯` menu (the shown one from the panel's big button).
struct TranslationLanguageRow: View {
    @Environment(ReaderViewModel.self) private var viewModel
    let controller: TranslationController

    var body: some View {
        let isShown = controller.target == viewModel.translationDisplayLanguage
        let isSelected = viewModel.translationIsShowing && isShown
        let done = controller.completedPageCount
        let total = controller.bookPageCount
        let isComplete = total > 0 && done >= total
        let needsStarting = viewModel.translationNeedsStarting(controller)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: PanelySpacing.sm) {
                Button {
                    viewModel.chooseTranslationLanguage(controller.target)
                } label: {
                    HStack(spacing: PanelySpacing.sm) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isSelected ? PanelyColor.accentPrimary : PanelyColor.textSecondary)
                        Text(verbatim: controller.target.displayName(in: viewModel.localization.locale))
                        Spacer(minLength: PanelySpacing.xs)
                        if isComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(PanelyColor.accentPrimary)
                        } else if controller.isWorking {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        if needsStarting {
                            // Nothing of it yet: picking it translates.
                            Label("Translate", systemImage: "play.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PanelyColor.accentPrimary)
                        } else {
                            Text(verbatim: "\(done)/\(total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(PanelyColor.textSecondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(needsStarting ? Text("Not translated yet — click to translate this book into it") : Text(verbatim: ""))

                if !isShown {
                    jobMenu(isComplete: isComplete, hasProgress: done > 0)
                }
            }
            // The shown language's status is the panel's status line.
            if !isShown, controller.hasActiveJob || controller.notice != nil {
                Group {
                    if let notice = controller.notice {
                        Text(verbatim: notice.message(locale: viewModel.localization.locale))
                    } else {
                        TranslationStatusText(translation: controller)
                    }
                }
                .font(.caption)
                .foregroundStyle(PanelyColor.textSecondary)
                .padding(.leading, 26)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func jobMenu(isComplete: Bool, hasProgress: Bool) -> some View {
        let isRunning = controller.isWorking || controller.phase == .queued
        return Menu {
            if !isComplete {
                if isRunning {
                    Button("Pause") { viewModel.translationManager.pause(controller) }
                } else {
                    Button(hasProgress ? "Resume" : "Translate This Book") {
                        viewModel.startTranslating(into: controller.target)
                    }
                }
            }
            if controller.hasActiveJob {
                Button("Stop") { viewModel.translationManager.stop(controller) }
            }
            Button("Show This Language") { viewModel.showTranslation(in: controller.target) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Translate, pause or stop this language")
    }
}

/// One line describing where the job is: detecting, preparing (with the
/// first-run warning), translating with an estimate, paused or done.
struct TranslationStatusText: View {
    let translation: TranslationController

    var body: some View {
        Self.text(for: translation)
    }

    /// As `Text`, to run on with other text (the panel's status line).
    static func text(for translation: TranslationController) -> Text {
        let done = translation.completedPageCount
        let total = translation.bookPageCount
        switch translation.phase {
        case .detectingLanguage:
            return Text("Detecting the book's language…")
        case .preparing:
            if translation.isFirstRunForThisBuild {
                return Text("Preparing translation models — the first time takes 1–2 minutes…")
            } else {
                return Text("Preparing…")
            }
        case .translating:
            if let remaining = translation.remainingSeconds {
                if remaining < 60 {
                    return Text("Translating · \(done)/\(total) pages · less than a minute left")
                } else {
                    return Text("Translating · \(done)/\(total) pages · about \(Int((remaining / 60).rounded(.up))) min left")
                }
            } else {
                return Text("Translating · \(done)/\(total) pages")
            }
        case .paused:
            if translation.isWaitingForBookToReopen {
                return Text("Paused · open this book to continue · \(done)/\(total) pages")
            } else {
                return Text("Paused · \(done)/\(total) pages")
            }
        case .queued:
            return Text("Waiting for another book · \(done)/\(total) pages")
        case .idle:
            if total > 0 && done >= total {
                return Text("All \(total) pages translated")
            } else {
                return Text("\(done) of \(total) pages translated")
            }
        }
    }
}

/// Floating progress pill shown over the page while a job runs or is paused,
/// independent of the auto-hiding toolbar — so progress stays visible while
/// reading.
struct TranslationProgressHUD: View {
    @Environment(ReaderViewModel.self) private var viewModel

    var body: some View {
        let translation = viewModel.translation
        if viewModel.translationFeatureAvailable, translation.phase != .idle {
            HStack(spacing: PanelySpacing.sm) {
                let running = translation.isWorking || translation.phase == .queued
                if translation.isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: translation.phase == .queued ? "hourglass" : "pause.circle")
                }
                Text(verbatim: translation.target.displayName(in: viewModel.localization.locale))
                    .font(.system(size: 12, weight: .semibold))
                TranslationStatusText(translation: translation)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    running ? viewModel.pauseTranslating() : viewModel.startTranslatingCurrentBook()
                } label: {
                    Image(systemName: running ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                .help(running ? "Pause" : "Resume")
                Button {
                    viewModel.stopTranslating()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Stop")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 420)
            .background(.black.opacity(0.78), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

/// The one thing to do next for the language the book is shown in, as a
/// full-width button — download the model, translate, pause or resume — with
/// one status line under it (progress, the model), so neither has to be
/// hunted for.
struct TranslationPrimaryAction: View {
    @Environment(ReaderViewModel.self) private var viewModel

    private enum Action {
        case translate
        case resume
        case pause
        case downloadModel
        case downloadingModel
        case done(Int)
    }

    private var model: TranslationModelStore { viewModel.translationManager.model }

    private var action: Action {
        if model.isDownloading { return .downloadingModel }
        if !model.isInstalled { return .downloadModel }
        let controller = viewModel.translation
        let done = controller.completedPageCount
        let total = controller.bookPageCount
        if total > 0, done >= total { return .done(total) }
        if controller.isWorking || controller.phase == .queued { return .pause }
        return done > 0 || controller.phase == .paused ? .resume : .translate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelySpacing.xs) {
            actionButton
            statusLine
        }
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch action {
        case .translate:
            prominentButton("Translate This Book", systemImage: "play.fill") {
                viewModel.startTranslatingCurrentBook()
            }
        case .resume:
            prominentButton("Resume Translation", systemImage: "play.fill") {
                viewModel.startTranslatingCurrentBook()
            }
        case .pause:
            HStack(spacing: PanelySpacing.xs) {
                Button {
                    viewModel.pauseTranslating()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    viewModel.stopTranslating()
                } label: {
                    Label("Stop", systemImage: "xmark")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        case .downloadModel:
            prominentButton("Download Translation Model (\(TranslationModelSize.text(model.model.bytes)))", systemImage: "arrow.down.circle") {
                model.download()
            }
        case .downloadingModel:
            TranslationModelDownloadProgress(model: model)
        case let .done(total):
            Label("All \(total) pages translated", systemImage: "checkmark.circle.fill")
                .foregroundStyle(PanelyColor.textSecondary)
        }
    }

    private func prominentButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    /// Where things stand, in one line: the job (or why it stopped) and the
    /// model — always mentioned, so it's clear what translates.
    private var statusLine: some View {
        (jobStatus + modelStatus)
            .font(.caption)
            .foregroundStyle(PanelyColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var jobStatus: Text {
        let controller = viewModel.translation
        let separator = Text(verbatim: " · ")
        switch controller.notice {
        case .needsModelDownload?:
            // The big button says it.
            return Text(verbatim: "")
        case let notice?:
            return Text(verbatim: notice.message(locale: viewModel.localization.locale)) + separator
        case nil:
            guard controller.hasActiveJob else { return Text(verbatim: "") }
            return TranslationStatusText.text(for: controller) + separator
        }
    }

    private var modelStatus: Text {
        switch model.state {
        case .installed:
            return Text("Translated on this Mac by \(model.model.displayName)")
        case .notInstalled:
            return Text("Downloaded once, then everything is translated on this Mac")
        case .downloading, .verifying:
            return Text(verbatim: "")
        case let .failed(reason):
            return Text("The download stopped: \(reason)")
        }
    }
}

/// The model's download under way: a bar, how much is in, and Cancel.
/// Shared by the panel and Settings.
struct TranslationModelDownloadProgress: View {
    let model: TranslationModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: PanelySpacing.xs) {
                if let fraction = model.fractionDownloaded {
                    ProgressView(value: fraction)
                        .tint(PanelyColor.accentPrimary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Button("Cancel") { model.cancelDownload() }
                    .controlSize(.small)
            }
            Group {
                switch model.state {
                case let .downloading(received, total):
                    Text("Downloading the translation model · \(TranslationModelSize.text(received)) of \(TranslationModelSize.text(total))")
                case .verifying:
                    Text("Checking the download…")
                case .notInstalled, .installed, .failed:
                    Text(verbatim: "")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(PanelyColor.textSecondary)
        }
    }
}

/// "Download…" for the model, for the status banner. Once it's in,
/// `TranslationManager` restarts the jobs that were waiting for it.
struct TranslationModelDownloadButton: View {
    @Environment(ReaderViewModel.self) private var viewModel

    private var model: TranslationModelStore { viewModel.translationManager.model }

    var body: some View {
        if model.isDownloading {
            HStack(spacing: PanelySpacing.xs) {
                ProgressView()
                    .controlSize(.small)
                if let fraction = model.fractionDownloaded {
                    Text(verbatim: fraction.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                } else {
                    Text("Downloading…")
                }
            }
        } else {
            Button("Download (\(TranslationModelSize.text(model.model.bytes)))…") {
                model.download()
            }
        }
    }
}

/// "3.35 GB" — decimal, as the download size is quoted on the web.
enum TranslationModelSize {
    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Translation jobs for books other than the open one: progress, pause or
/// resume, stop, and a way back to the book.
struct TranslationJobsList: View {
    @Environment(ReaderViewModel.self) private var viewModel
    let jobs: [TranslationController]
    /// Whether to end with the note that quitting stops translating.
    var showsQuitNote = true

    var body: some View {
        VStack(alignment: .leading, spacing: PanelySpacing.sm) {
            ForEach(jobs, id: \.bookKey) { job in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: PanelySpacing.xs) {
                        Text(verbatim: job.label(locale: viewModel.localization.locale))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: PanelySpacing.xs)
                        if job.notice == nil {
                            Button {
                                if job.isWorking || job.phase == .queued {
                                    viewModel.translationManager.pause(job)
                                } else {
                                    viewModel.translationManager.start(job)
                                }
                            } label: {
                                Image(systemName: job.isWorking || job.phase == .queued ? "pause.fill" : "play.fill")
                            }
                            .buttonStyle(.plain)
                            .help(job.isWorking || job.phase == .queued ? "Pause" : "Resume")
                            // Its pages are gone until the book is open again.
                            .disabled(job.isWaitingForBookToReopen)
                        }
                        Button {
                            viewModel.translationManager.stop(job)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .help(job.notice == nil ? "Stop" : "Dismiss")
                        Button {
                            viewModel.openTranslationJobBook(job)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                        }
                        .buttonStyle(.plain)
                        .help("Open This Book")
                        .disabled(job.bookURL == nil)
                    }
                    ProgressView(value: Double(job.completedPageCount), total: Double(max(1, job.bookPageCount)))
                        .tint(PanelyColor.accentPrimary)
                    if let notice = job.notice {
                        Label {
                            Text(verbatim: notice.message(locale: viewModel.localization.locale))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        TranslationStatusText(translation: job)
                            .font(.caption)
                            .foregroundStyle(PanelyColor.textSecondary)
                    }
                }
            }
            if showsQuitNote && !jobs.isEmpty {
                TranslationCaveat(
                    systemImage: "info.circle",
                    text: "Quitting Panely stops translating. Finished pages are kept, and the rest continues when you start again."
                )
            }
        }
    }
}

/// A one-line limitation or warning, in place where it applies.
struct TranslationCaveat: View {
    let systemImage: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(systemImage.hasPrefix("exclamationmark") ? Color.orange : PanelyColor.textSecondary)
        }
        .font(.caption)
        .foregroundStyle(PanelyColor.textSecondary)
    }
}

/// Over the page while anything runs in the background — another book's
/// translation, an export — so it stays visible wherever you are, and once an
/// export finishes until it's been seen. Opens the jobs window.
struct BackgroundTranslationsIndicator: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let content {
            Button {
                openWindow(id: JobsWindowView.windowID)
            } label: {
                HStack(spacing: PanelySpacing.xs) {
                    content.icon
                    content.text
                }
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: 380)
                .background(.black.opacity(0.65), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Show Jobs (⌥⌘J)")
            .transition(.opacity)
        }
    }

    /// Exports first (the reader started them to get a file), then other
    /// books' translations, then a finished export not yet looked at.
    private var content: (icon: AnyView, text: Text)? {
        guard viewModel.translationFeatureAvailable else { return nil }
        let exports = viewModel.translationExports
        let exporting = exports.activeJobs
        if let lead = exporting.first(where: { if case .exporting = $0.stage { true } else { false } }) ?? exporting.first {
            let progress: Text
            if case let .exporting(done, total) = lead.stage {
                progress = Text(verbatim: " \(done)/\(total)")
            } else if let translation = lead.translation {
                progress = Text(verbatim: " \(translation.completedPageCount)/\(translation.bookPageCount)")
            } else {
                progress = Text(verbatim: "")
            }
            let text = exporting.count > 1
                ? Text("Exporting \(exporting.count) books · \(lead.title)") + progress
                : Text("Exporting · \(lead.title)") + progress
            return (AnyView(ProgressView().controlSize(.mini)), text)
        }

        let jobs = viewModel.translationManager.backgroundJobs
        if let lead = jobs.first(where: \.isWorking) ?? jobs.first {
            let stopped = jobs.filter { $0.notice != nil }
            let name = lead.label(locale: viewModel.localization.locale)
            if !lead.isWorking && !stopped.isEmpty {
                return (
                    AnyView(Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)),
                    Text("Translation stopped in another book — click for details")
                )
            }
            let icon = lead.isWorking
                ? AnyView(ProgressView().controlSize(.mini))
                : AnyView(Image(systemName: "pause.circle"))
            let text = jobs.count > 1
                ? Text("Translating \(jobs.count) other books · \(name) \(lead.completedPageCount)/\(lead.bookPageCount)")
                : Text("Translating another book · \(name) \(lead.completedPageCount)/\(lead.bookPageCount)")
            return (icon, text)
        }

        if exports.stoppedJobs.contains(where: { if case .failed = $0.stage { true } else { false } }) {
            return (
                AnyView(Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)),
                Text("An export stopped — click for details")
            )
        }
        if exports.unseenFinishedCount > 0 {
            return (
                AnyView(Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)),
                Text("Export finished — click to see")
            )
        }
        return nil
    }
}

extension TranslationController {
    /// "Title → Language", for lists of jobs.
    func label(locale: Locale) -> String {
        "\(title) → \(target.displayName(in: locale))"
    }
}

/// Picks the default language new series are shown in: "System Default"
/// (the interface language) or a specific one.
struct TranslationTargetPicker: View {
    let viewModel: ReaderViewModel

    var body: some View {
        let locale = viewModel.localization.locale
        let system = TranslationLanguage.defaultTarget(forInterfaceLanguage: viewModel.localization.language)
        Picker("Default Language", selection: Binding(
            get: { viewModel.translationTargetChoice },
            set: { viewModel.translationTargetChoice = $0 }
        )) {
            Text("System Default (\(system.displayName(in: locale)))").tag(TranslationLanguage?.none)
            Divider()
            ForEach(TranslationLanguage.allCases) { language in
                Text(verbatim: language.displayName(in: locale)).tag(TranslationLanguage?.some(language))
            }
        }
    }
}
