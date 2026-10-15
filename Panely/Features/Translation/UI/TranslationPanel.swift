import SwiftUI
import Translation

/// The translation panel: translating the open book, nothing else. Opened
/// from the toolbar's ▾ menu (or the button itself before there's anything
/// to show).
///
/// Top to bottom, by how often each is needed:
/// - **What to do next** — one big button (translate, download the pack,
///   pause, resume) and one status line (progress, the pack).
/// - **View** — the original or one of the book's languages; other languages
///   start, pause or stop from their `⋯` menu.
/// - **This book & series** — collapsed: the book's language, auto-translate,
///   translating the whole series, and the limits that apply.
/// - **Edit Balloons** — into edit mode, where correcting happens on the page.
///
/// Elsewhere on purpose: on/off and switching languages (toolbar, ⇧⌘T),
/// running progress (the pill over the page), other books' jobs (their own
/// pill), editing (edit mode's bar) and app-wide choices (Settings, ⚙︎).
struct TranslationPanel: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var showsBookSettings = false

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

            if #available(macOS 26.0, *), viewModel.translationSourceLanguage != viewModel.translationDisplayLanguage {
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

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: PanelySpacing.sm) {
                Button {
                    viewModel.showTranslation(in: controller.target)
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
                        Text(verbatim: "\(done)/\(total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(PanelyColor.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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

/// Thin bar marking translated pages across the book, under the page slider.
struct TranslatedPagesBar: View {
    let pageCount: Int
    let translated: Set<Int>

    var body: some View {
        Canvas { context, size in
            guard pageCount > 0 else { return }
            let width = size.width / CGFloat(pageCount)
            var runStart: Int?
            for index in 0...pageCount {
                let isTranslated = index < pageCount && translated.contains(index)
                if isTranslated, runStart == nil { runStart = index }
                if !isTranslated, let start = runStart {
                    let rect = CGRect(x: CGFloat(start) * width, y: 0, width: CGFloat(index - start) * width, height: size.height)
                    context.fill(Path(rect), with: .color(PanelyColor.accentPrimary.opacity(0.55)))
                    runStart = nil
                }
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

/// The one thing to do next for the language the book is shown in, as a
/// full-width button — translate, download the language pack, pause or
/// resume — with one status line under it (progress, the pack), so neither
/// has to be hunted for.
///
/// Downloading needs SwiftUI's `translationTask` — the only API that may
/// prompt for a language pack — so it starts here, not in the background job;
/// `LanguagePackDownloads` keeps track of it from then on.
@available(macOS 26.0, *)
struct TranslationPrimaryAction: View {
    @Environment(ReaderViewModel.self) private var viewModel

    @State private var downloadConfiguration: TranslationSession.Configuration?
    /// Which pack `downloadConfiguration` asks for.
    @State private var downloadRequest: LanguagePackDownloads.Pack?

    private enum Action {
        case translate
        case resume
        case pause
        case downloadPack(LanguagePackDownloads.Pack)
        case downloadingPack
        case unsupported
        case done(Int)
    }

    private var downloads: LanguagePackDownloads { viewModel.translationManager.languagePacks }

    /// The pack the shown language needs; `nil` until the book's language is known.
    private var pack: LanguagePackDownloads.Pack? {
        viewModel.translationSourceLanguage.map {
            .init(source: $0, target: viewModel.translationDisplayLanguage, mode: viewModel.translationMode)
        }
    }

    private var action: Action {
        let controller = viewModel.translation
        if case let .needsLanguageDownload(source, target) = controller.notice {
            let needed = LanguagePackDownloads.Pack(source: source, target: target, mode: viewModel.translationMode)
            return downloads.isDownloading(needed) ? .downloadingPack : .downloadPack(needed)
        }
        if let pack {
            if downloads.isDownloading(pack) { return .downloadingPack }
            switch downloads.status(of: pack) {
            case .needsDownload: return .downloadPack(pack)
            case .unsupported: return .unsupported
            case .installed, nil: break
            }
        }
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
            if let pack, downloads.isDownloading(pack) {
                TranslationCaveat(systemImage: "clock", text: LanguagePackDownloadingLabel.note)
            }
        }
        .task(id: pack) {
            if let pack { await downloads.refresh(pack) }
        }
        .translationTask(downloadConfiguration) { [pack = downloadRequest, downloads] session in
            guard let pack else { return }
            await LanguagePackDownloads.download(pack, using: session, into: downloads)
        }
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
        case let .downloadPack(pack):
            prominentButton("Download Language Pack…", systemImage: "arrow.down.circle") {
                requestDownload(pack)
            }
        case .downloadingPack:
            Button {} label: {
                HStack(spacing: PanelySpacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading Language Pack…")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(true)
        case .unsupported:
            prominentButton("Translate This Book", systemImage: "play.fill") {}
                .disabled(true)
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
    /// language pack — always mentioned, so it's clear it exists.
    private var statusLine: some View {
        (jobStatus + packStatus)
            .font(.caption)
            .foregroundStyle(PanelyColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var jobStatus: Text {
        let controller = viewModel.translation
        let separator = Text(verbatim: " · ")
        switch controller.notice {
        case .needsLanguageDownload?:
            // The big button says it.
            return Text(verbatim: "")
        case let notice?:
            return Text(verbatim: notice.message(locale: viewModel.localization.locale)) + separator
        case nil:
            guard controller.hasActiveJob else { return Text(verbatim: "") }
            return TranslationStatusText.text(for: controller) + separator
        }
    }

    private var packStatus: Text {
        guard let pack else { return Text("Language pack checked once the book's language is known") }
        if downloads.isDownloading(pack) { return Text("Downloading Language Pack…") }
        switch downloads.status(of: pack) {
        case nil: return Text("Checking the language pack…")
        case .installed: return Text("Language pack installed")
        case .needsDownload: return Text("Language pack not installed")
        case .unsupported: return Text("This language pair isn't supported")
        }
    }

    private func requestDownload(_ pack: LanguagePackDownloads.Pack) {
        downloads.begin(pack)
        if downloadConfiguration != nil, downloadRequest == pack {
            // Same pack again (e.g. the first prompt was dismissed): re-run.
            downloadConfiguration?.invalidate()
        } else {
            downloadRequest = pack
            downloadConfiguration = TranslationAvailability.configuration(from: pack.source, to: pack.target, mode: pack.mode)
        }
    }
}

/// "Download…" for a missing language pack, for the status banner. Once the
/// pack is in, `TranslationManager` restarts the jobs that were waiting for it.
@available(macOS 26.0, *)
struct LanguagePackDownloadButton: View {
    @Environment(ReaderViewModel.self) private var viewModel
    let source: TranslationLanguage
    let target: TranslationLanguage
    let mode: TranslationMode

    @State private var configuration: TranslationSession.Configuration?

    private var downloads: LanguagePackDownloads { viewModel.translationManager.languagePacks }
    private var pack: LanguagePackDownloads.Pack { .init(source: source, target: target, mode: mode) }

    var body: some View {
        Group {
            if downloads.isDownloading(pack) {
                LanguagePackDownloadingLabel()
                    .help(Text(LanguagePackDownloadingLabel.note))
            } else {
                Button("Download…") {
                    downloads.begin(pack)
                    if configuration == nil {
                        configuration = TranslationAvailability.configuration(from: source, to: target, mode: mode)
                    } else {
                        configuration?.invalidate()
                    }
                }
            }
        }
        .translationTask(configuration) { [pack, downloads] session in
            await LanguagePackDownloads.download(pack, using: session, into: downloads)
        }
    }
}

/// Stands in for "Download…" while a pack downloads. Apple Translation's own
/// download window shows no real progress — its bar can sit still for
/// minutes — so this says the download is under way and why it may look stuck.
struct LanguagePackDownloadingLabel: View {
    static let note: LocalizedStringKey = "Language packs are large, so this can take several minutes. The progress bar in the system window may not move for a while."

    var body: some View {
        HStack(spacing: PanelySpacing.xs) {
            ProgressView()
                .controlSize(.small)
            Text("Downloading…")
        }
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

/// Shown over the page while books other than the open one are being
/// translated, so background progress stays visible wherever you are.
/// Opens the jobs list.
struct BackgroundTranslationsIndicator: View {
    @Environment(ReaderViewModel.self) private var viewModel
    @State private var showsJobs = false

    var body: some View {
        let jobs = viewModel.translationManager.backgroundJobs
        if viewModel.translationFeatureAvailable, let lead = jobs.first(where: \.isWorking) ?? jobs.first {
            Button {
                showsJobs.toggle()
            } label: {
                HStack(spacing: PanelySpacing.xs) {
                    let stopped = jobs.filter { $0.notice != nil }
                    if lead.isWorking {
                        ProgressView()
                            .controlSize(.mini)
                    } else if !stopped.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "pause.circle")
                    }
                    let name = lead.label(locale: viewModel.localization.locale)
                    if !lead.isWorking && !stopped.isEmpty {
                        Text("Translation stopped in another book — click for details")
                    } else if jobs.count > 1 {
                        Text("Translating \(jobs.count) other books · \(name) \(lead.completedPageCount)/\(lead.bookPageCount)")
                    } else {
                        Text("Translating another book · \(name) \(lead.completedPageCount)/\(lead.bookPageCount)")
                    }
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
            .popover(isPresented: $showsJobs, arrowEdge: .top) {
                TranslationJobsList(jobs: jobs)
                    .padding(PanelySpacing.md)
                    .frame(width: 320)
                    .environment(viewModel)
                    // Popovers don't inherit the window's `\.locale`.
                    .environment(\.locale, viewModel.localization.locale)
            }
            .transition(.opacity)
        }
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
