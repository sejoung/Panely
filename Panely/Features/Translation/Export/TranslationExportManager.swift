import Foundation
import Observation

/// App-wide owner of translated-book exports: the jobs in progress, the
/// finished ones (kept across launches), where they're saved, and the
/// choices last made in the export sheet.
///
/// Jobs run in the background while the reader goes on reading. Each waits
/// for its book's translation through the usual translation queue, then the
/// exports render one at a time — rendering is heavy on memory, and the
/// translation of the next book keeps running alongside.
@Observable
@MainActor
final class TranslationExportManager {
    private(set) var jobs: [TranslationExportJob] = []
    private(set) var history: [TranslationExportRecord] = []
    /// Where exports are saved, chosen once in the sheet. `nil` until then.
    private(set) var destination: URL?
    /// Exports finished since the jobs window was last looked at — the pill
    /// over the page says so until then.
    private(set) var unseenFinishedCount = 0
    var options: TranslationExportOptions? {
        didSet { if let options { defaults.saveCodable(options, forKey: Self.optionsKey) } }
    }

    @ObservationIgnored private let defaults: any KeyValueStoring
    /// Waiting to render, in order; the first one renders once `isRendering`
    /// clears.
    @ObservationIgnored private var renderQueue: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var isRendering = false

    nonisolated static let historyKey = "panely.translationExport.history"
    nonisolated static let destinationKey = "panely.translationExport.destination"
    nonisolated static let optionsKey = "panely.translationExport.options"
    nonisolated static let maxHistory = 50

    init(defaults: any KeyValueStoring) {
        self.defaults = defaults
        history = defaults.loadCodable([TranslationExportRecord].self, forKey: Self.historyKey) ?? []
        options = defaults.loadCodable(TranslationExportOptions.self, forKey: Self.optionsKey)
        if let data = defaults.data(forKey: Self.destinationKey),
           let resolved = SecurityScopedBookmark.resolve(data) {
            destination = resolved.url
            if resolved.isStale, let refreshed = SecurityScopedBookmark.refreshedData(for: resolved.url) {
                defaults.set(refreshed, forKey: Self.destinationKey)
            }
        }
    }

    var activeJobs: [TranslationExportJob] { jobs.filter(\.isActive) }
    /// Stopped jobs (failed or cancelled) kept so the reason shows.
    var stoppedJobs: [TranslationExportJob] { jobs.filter { !$0.isActive && $0.stage != .finished } }

    /// Translation jobs an export is waiting on — listed under the export,
    /// not again on their own.
    var translationsInUse: [TranslationController] {
        jobs.compactMap(\.translation)
    }

    // MARK: - Destination

    /// Remember `url` (picked in an open panel, so the app may write there)
    /// as where exports go.
    func setDestination(_ url: URL) {
        destination = url
        if let data = try? SecurityScopedBookmark.data(for: url) {
            defaults.set(data, forKey: Self.destinationKey)
        }
    }

    // MARK: - Jobs

    func add(_ job: TranslationExportJob) {
        jobs.append(job)
    }

    /// Stop a job; it stays listed as cancelled until dismissed.
    func cancel(_ job: TranslationExportJob) {
        job.task?.cancel()
        job.setStage(.cancelled)
    }

    /// Remove a stopped job from the list.
    func dismiss(_ job: TranslationExportJob) {
        guard !job.isActive else { return }
        jobs.removeAll { $0 === job }
    }

    /// A job wrote its book.
    func finish(_ job: TranslationExportJob, result: TranslationExportWriter.Result, pageCount: Int) {
        job.setStage(.finished)
        jobs.removeAll { $0 === job }
        let record = TranslationExportRecord(
            title: job.title,
            target: job.options.target,
            format: job.options.format,
            path: result.url.path,
            pageCount: pageCount,
            bytes: result.bytes,
            date: Date()
        )
        history.insert(record, at: 0)
        if history.count > Self.maxHistory { history.removeLast(history.count - Self.maxHistory) }
        defaults.saveCodable(history, forKey: Self.historyKey)
        unseenFinishedCount += 1
    }

    /// The jobs window was opened.
    func markFinishedSeen() {
        unseenFinishedCount = 0
    }

    /// Forget the finished list (the files stay where they are).
    func clearHistory() {
        history = []
        defaults.saveCodable(history, forKey: Self.historyKey)
        unseenFinishedCount = 0
        jobs.removeAll { !$0.isActive }
    }

    func removeRecord(_ record: TranslationExportRecord) {
        history.removeAll { $0.id == record.id }
        defaults.saveCodable(history, forKey: Self.historyKey)
    }

    // MARK: - Rendering, one at a time

    /// Wait for the exports ahead to finish rendering. Pair with
    /// `endRendering()`.
    func beginRendering() async {
        guard isRendering else {
            isRendering = true
            return
        }
        await withCheckedContinuation { renderQueue.append($0) }
    }

    func endRendering() {
        if renderQueue.isEmpty {
            isRendering = false
        } else {
            renderQueue.removeFirst().resume()
        }
    }
}
