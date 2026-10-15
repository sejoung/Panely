import AppKit
import SwiftUI

/// Window › Jobs (⌥⌘J): everything running in the background in one place —
/// translations and exports, whichever book they're for — and the exported
/// books, ready to show in Finder or open. A window rather than a popover so
/// it can stay up beside the reader while another book is read.
struct JobsWindowView: View {
    @Environment(ReaderViewModel.self) private var viewModel

    static let windowID = "jobs"

    var body: some View {
        let exports = viewModel.translationExports
        let inUse = exports.translationsInUse
        let translations = viewModel.translationManager.allJobs.filter { job in !inUse.contains { $0 === job } }
        let active = exports.activeJobs
        let stopped = exports.stoppedJobs
        let history = exports.history

        ScrollView {
            VStack(alignment: .leading, spacing: PanelySpacing.lg) {
                if active.isEmpty && translations.isEmpty && stopped.isEmpty && history.isEmpty {
                    emptyState
                }
                if !active.isEmpty || !translations.isEmpty {
                    section("In Progress") {
                        ForEach(active) { job in
                            ExportJobRow(job: job)
                        }
                        if !translations.isEmpty {
                            TranslationJobsList(jobs: translations, showsQuitNote: false)
                        }
                    }
                }
                if !stopped.isEmpty {
                    section("Stopped") {
                        ForEach(stopped) { job in
                            ExportJobRow(job: job)
                        }
                    }
                }
                if !history.isEmpty {
                    section("Exported") {
                        ForEach(history) { record in
                            ExportRecordRow(record: record)
                        }
                    } trailing: {
                        Button("Clear List") {
                            exports.clearHistory()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Forget these exports. The files stay where they are.")
                    }
                }
                if !active.isEmpty || !translations.isEmpty {
                    TranslationCaveat(
                        systemImage: "info.circle",
                        text: "Quitting Panely stops translating and exporting. Translated pages are kept, so starting again picks up where it left off."
                    )
                }
            }
            .padding(PanelySpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 320)
        .background(PanelyColor.bgPrimary)
        .onAppear { exports.markFinishedSeen() }
        .onChange(of: exports.unseenFinishedCount) { _, count in
            if count > 0 { exports.markFinishedSeen() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: PanelySpacing.sm) {
            Image(systemName: "tray")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(PanelyColor.textSecondary)
            Text("Nothing in Progress")
                .font(.headline)
            Text("Translations and exports show here while they run, and exported books stay listed. Export a book from the translation menu in the toolbar, File › Export Translated Book…, or a book's or folder's context menu in the library.")
                .font(.callout)
                .foregroundStyle(PanelyColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PanelySpacing.xl)
    }

    private func section<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        section(title, content: content) { EmptyView() }
    }

    private func section<Content: View, Trailing: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: PanelySpacing.sm) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PanelyColor.textSecondary)
                Spacer()
                trailing()
            }
            VStack(alignment: .leading, spacing: PanelySpacing.md) {
                content()
            }
            .padding(PanelySpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelyColor.bgSecondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// One export: the book and language, where it's at, and how to stop it —
/// or, once stopped, why and how to try again.
private struct ExportJobRow: View {
    @Environment(ReaderViewModel.self) private var viewModel
    let job: TranslationExportJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: PanelySpacing.xs) {
                Image(systemName: job.options.format.isArchive ? "doc.zipper" : "folder")
                    .foregroundStyle(PanelyColor.textSecondary)
                Text(verbatim: "\(job.title) → \(job.options.target.displayName(in: viewModel.localization.locale))")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: PanelySpacing.xs)
                if job.isActive {
                    if let translation = job.translation, translation.phase == .paused {
                        Button {
                            viewModel.translationManager.start(translation)
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Resume Translating")
                    }
                    Button {
                        viewModel.translationExports.cancel(job)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Cancel Export")
                } else {
                    Button("Try Again") {
                        viewModel.retryTranslationExport(job)
                    }
                    .controlSize(.small)
                    Button {
                        viewModel.translationExports.dismiss(job)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        switch job.stage {
        case .preparing:
            ProgressView()
                .progressViewStyle(.linear)
            Text("Getting the book ready…")
                .font(.caption)
                .foregroundStyle(PanelyColor.textSecondary)
        case .translating:
            if let translation = job.translation {
                ProgressView(value: Double(translation.completedPageCount), total: Double(max(1, translation.bookPageCount)))
                    .tint(PanelyColor.accentPrimary)
                (Text("Translating first") + Text(verbatim: " · ") + TranslationStatusText.text(for: translation))
                    .font(.caption)
                    .foregroundStyle(PanelyColor.textSecondary)
            }
        case .waiting:
            ProgressView(value: 0)
            Text("Translated — waiting for the export ahead of it")
                .font(.caption)
                .foregroundStyle(PanelyColor.textSecondary)
        case let .exporting(done, total):
            ProgressView(value: Double(done), total: Double(max(1, total)))
                .tint(PanelyColor.accentPrimary)
            Text("Exporting · \(done)/\(total) pages")
                .font(.caption)
                .foregroundStyle(PanelyColor.textSecondary)
        case .finished:
            EmptyView()
        case let .failed(reason):
            Label {
                Text(verbatim: reason)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption)
        case .cancelled:
            Text("Cancelled")
                .font(.caption)
                .foregroundStyle(PanelyColor.textSecondary)
        }
    }
}

/// A finished export: what and where, with Show in Finder and Open.
private struct ExportRecordRow: View {
    @Environment(ReaderViewModel.self) private var viewModel
    let record: TranslationExportRecord

    var body: some View {
        HStack(alignment: .top, spacing: PanelySpacing.sm) {
            Image(systemName: record.format.isArchive ? "doc.zipper" : "folder")
                .foregroundStyle(PanelyColor.accentPrimary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: record.url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(record.path)
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundStyle(PanelyColor.textSecondary)
            }
            Spacer(minLength: PanelySpacing.xs)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([record.url])
            }
            .controlSize(.small)
            Button("Open") {
                viewModel.openExportedBook(record)
            }
            .controlSize(.small)
            .help("Open in Panely")
        }
        .contextMenu {
            Button("Remove from List") {
                viewModel.translationExports.removeRecord(record)
            }
        }
    }

    private var details: String {
        let locale = viewModel.localization.locale
        let pages = String(localized: "\(record.pageCount) pages", bundle: .localized)
        let size = ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file)
        let date = record.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        return [record.target.displayName(in: locale), pages, size, date].joined(separator: " · ")
    }
}
