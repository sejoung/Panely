import SwiftUI
import Translation

/// The translation assist's controls for the open book, opened from the
/// toolbar.
///
/// - **View**: the original (translation off) or one of the book's
///   languages. Each language row shows its own progress and runs its own job;
///   picking one shows it, and the choice is remembered for the series.
/// - The book's own language (detected, remembered per series, correctable).
/// - Series translation, background jobs for other books, and caveats where
///   they apply.
struct TranslationPanel: View {
    @Environment(ReaderViewModel.self) private var viewModel

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
            HStack(spacing: PanelySpacing.xs) {
                Text("Translation")
                    .font(.headline)
                Text("Experimental")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(PanelyColor.bgTertiary, in: Capsule())
                    .foregroundStyle(PanelyColor.textSecondary)
            }

            sourceRow

            VStack(alignment: .leading, spacing: PanelySpacing.xs) {
                Text("View")
                    .font(.subheadline.weight(.semibold))
                originalRow
                ForEach(viewModel.translationLanguagesForBook, id: \.target) { controller in
                    TranslationLanguageRow(controller: controller)
                }
                addLanguageMenu
            }

            if #available(macOS 26.0, *), viewModel.translationSourceLanguage != viewModel.translationDisplayLanguage {
                TranslationPrimaryAction()
            }

            if viewModel.currentBookLivesInTemporaryFolder {
                TranslationCaveat(
                    systemImage: "exclamationmark.triangle",
                    text: "This book is an archive inside an archive. Its translation pauses when you open another book and continues when you come back."
                )
            }

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

            let others = viewModel.translationManager.backgroundJobs.filter { $0.bookKey != viewModel.translationManager.openBookKey }
            if !others.isEmpty {
                Divider()
                Text("Other Books")
                    .font(.subheadline.weight(.semibold))
                TranslationJobsList(jobs: others, showsQuitNote: false)
            }

            if !viewModel.translationManager.activeJobs.isEmpty {
                TranslationCaveat(
                    systemImage: "info.circle",
                    text: "Quitting Panely stops translating. Finished pages are kept, and the rest continues when you start again."
                )
            }

            Divider()

            Toggle("Translate This Series Automatically", isOn: autoBinding)
            Text("Click a balloon to see the original next to its translations.")
                .font(.caption)
                .foregroundStyle(PanelyColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PanelySpacing.md)
        .frame(width: 340, alignment: .leading)
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

    /// "Original" — translation off (⇧⌘T toggles back to the language).
    private var originalRow: some View {
        let isSelected = !viewModel.translationOverlayVisible
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

/// One of the open book's languages: pick it to show it, see its progress,
/// and start, pause or stop its job.
struct TranslationLanguageRow: View {
    @Environment(ReaderViewModel.self) private var viewModel
    let controller: TranslationController

    var body: some View {
        let isSelected = viewModel.translationOverlayVisible && controller.target == viewModel.translationDisplayLanguage
        let done = controller.completedPageCount
        let total = controller.bookPageCount
        let isComplete = total > 0 && done >= total
        let isRunning = controller.isWorking || controller.phase == .queued

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

                // The shown language's controls are the panel's main button.
                if controller.target != viewModel.translationDisplayLanguage {
                    if !isComplete {
                        Button {
                            if isRunning {
                                viewModel.translationManager.pause(controller)
                            } else {
                                viewModel.startTranslating(into: controller.target)
                            }
                        } label: {
                            Image(systemName: isRunning ? "pause.fill" : "play.fill")
                        }
                        .help(isRunning ? "Pause" : (done > 0 ? "Resume" : "Translate This Book"))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if controller.hasActiveJob {
                        Button {
                            viewModel.translationManager.stop(controller)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .help("Stop")
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            if controller.hasActiveJob || controller.notice != nil {
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
}

/// One line describing where the job is: detecting, preparing (with the
/// first-run warning), translating with an estimate, paused or done.
struct TranslationStatusText: View {
    let translation: TranslationController

    var body: some View {
        let done = translation.completedPageCount
        let total = translation.bookPageCount
        switch translation.phase {
        case .detectingLanguage:
            Text("Detecting the book's language…")
        case .preparing:
            if translation.isFirstRunForThisBuild {
                Text("Preparing translation models — the first time takes 1–2 minutes…")
            } else {
                Text("Preparing…")
            }
        case .translating:
            if let remaining = translation.remainingSeconds {
                if remaining < 60 {
                    Text("Translating · \(done)/\(total) pages · less than a minute left")
                } else {
                    Text("Translating · \(done)/\(total) pages · about \(Int((remaining / 60).rounded(.up))) min left")
                }
            } else {
                Text("Translating · \(done)/\(total) pages")
            }
        case .paused:
            if translation.isWaitingForBookToReopen {
                Text("Paused · open this book to continue · \(done)/\(total) pages")
            } else {
                Text("Paused · \(done)/\(total) pages")
            }
        case .queued:
            Text("Waiting for another book · \(done)/\(total) pages")
        case .idle:
            if total > 0 && done >= total {
                Text("All \(total) pages translated")
            } else {
                Text("\(done) of \(total) pages translated")
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
/// resume — with the pack's status under it, so neither has to be hunted for.
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
            packRow
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

    /// Always shown, installed or not, so it's clear the pack exists and
    /// where it's handled.
    private var packRow: some View {
        LabeledContent("Language Pack") {
            if let pack {
                if downloads.isDownloading(pack) {
                    LanguagePackDownloadingLabel()
                } else {
                    switch downloads.status(of: pack) {
                    case nil:
                        ProgressView()
                            .controlSize(.small)
                    case .installed:
                        Label("Installed", systemImage: "checkmark.circle.fill")
                    case .needsDownload:
                        Text("Not Installed")
                    case .unsupported:
                        Text("Not Supported")
                    }
                }
            } else {
                Text("Checked once the book's language is known")
            }
        }
        .font(.caption)
        .foregroundStyle(PanelyColor.textSecondary)
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
    /// The panel shows its own copy of the quit note.
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
