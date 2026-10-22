import Foundation
import Observation

/// App-wide owner of translation jobs.
///
/// A job is one book translated into one language, so a book can be read in
/// Korean while an English translation runs, and each language's progress
/// and results stay separate.
///
/// - `openBook` holds the open book's controllers, one per target language;
///   `displayTarget` picks the one shown (`current`).
/// - Closing a book keeps any controller that still has work in `background`,
///   where its job carries on; reopening the book reattaches to it, progress
///   and all. Finished background controllers are dropped — their results
///   live in the cache.
///
/// There's one model and it answers one request at a time, so only one job
/// runs at once and the rest wait as `.queued`. The job for what's on
/// screen takes precedence: starting it pauses a running job back into the
/// queue, and queued jobs resume as soon as the running one ends.
@Observable
@MainActor
final class TranslationManager {
    private(set) var openBook: [TranslationController] = []
    private(set) var displayTarget: TranslationLanguage = .english
    private(set) var background: [TranslationController] = []
    private(set) var openBookKey = ""

    let store: TranslationStore
    /// The model's download — shared by every book, the panel and Settings.
    let model: TranslationModelStore
    /// The model itself, for every controller.
    @ObservationIgnored let translator: any BalloonTranslating
    /// Handed to each controller (`TranslationController.makeAnalyzer`).
    @ObservationIgnored private let makeAnalyzer: (@Sendable ([ComicPage], TranslationLanguage) -> any PageAnalyzing)?
    @ObservationIgnored private let defaults: any KeyValueStoring
    @ObservationIgnored private var openBookTitle = ""
    @ObservationIgnored private var openBookURL: URL?
    /// Shown while no book is open.
    @ObservationIgnored private let placeholder: TranslationController
    /// Set while the manager itself stops a job, so that stop doesn't trigger
    /// starting the next one before the manager's own choice.
    @ObservationIgnored private var isScheduling = false

    init(
        store: TranslationStore,
        defaults: any KeyValueStoring,
        translator: any BalloonTranslating = GemmaTranslator.shared,
        model: TranslationModelStore? = nil,
        makeAnalyzer: (@Sendable ([ComicPage], TranslationLanguage) -> any PageAnalyzing)? = nil
    ) {
        self.store = store
        self.defaults = defaults
        self.translator = translator
        self.makeAnalyzer = makeAnalyzer
        self.model = model ?? TranslationModelStore()
        placeholder = TranslationController(store: store, defaults: defaults, translator: translator)
        self.model.onInstalled = { [weak self] in
            self?.modelInstalled()
        }
    }

    /// The controller for the open book in the language it's shown in.
    var current: TranslationController {
        openBook.first { $0.target == displayTarget } ?? placeholder
    }

    /// Every job in progress, waiting or paused.
    var activeJobs: [TranslationController] {
        (openBook + background).filter(\.hasActiveJob)
    }

    /// Jobs other than the one on screen: other books, and the open book in
    /// other languages. Includes jobs that stopped on an error, kept until
    /// dismissed so a background failure isn't silent.
    var backgroundJobs: [TranslationController] {
        openBook.filter { $0 !== current && $0.hasActiveJob } + background.filter(Self.isWorthKeeping)
    }

    /// Every job the jobs window lists: running, waiting, paused, or stopped
    /// on an error — the open book's included.
    var allJobs: [TranslationController] {
        (openBook + background).filter(Self.isWorthKeeping)
    }

    // MARK: - Open book

    /// A book is being opened. Its controllers still running in the
    /// background (any language) are reattached.
    func beginBook(key: String, title: String, url: URL?) {
        guard key != openBookKey || openBook.isEmpty else { return }
        detachOpenBook()
        openBookKey = key
        openBookTitle = title
        openBookURL = url
        let reattached = background.filter { $0.bookKey == key }
        background.removeAll { $0.bookKey == key }
        for controller in reattached { controller.bookReopened() }
        openBook = reattached
    }

    /// The open book closed: keep its controllers that have work (pausing
    /// those whose pages vanish with the book), drop the rest.
    func detachOpenBook() {
        for controller in openBook {
            if controller.hasActiveJob, controller.requiresOpenBook {
                controller.pauseUntilBookReopens()
            }
            if Self.isWorthKeeping(controller) {
                background.append(controller)
            } else {
                controller.clear()
            }
        }
        openBook = []
        openBookKey = ""
        openBookURL = nil
    }

    /// The open book's controller for `target`; `isNew` when the caller has to
    /// `reload` it.
    func controller(for target: TranslationLanguage) -> (controller: TranslationController, isNew: Bool) {
        if let existing = openBook.first(where: { $0.target == target && $0.isConfigured }) {
            return (existing, false)
        }
        let controller = makeController(bookKey: openBookKey, title: openBookTitle, bookURL: openBookURL)
        openBook.append(controller)
        return (controller, true)
    }

    func setDisplayTarget(_ language: TranslationLanguage) {
        displayTarget = language
    }

    // MARK: - Other books

    /// A controller for a book that isn't open (e.g. another volume of the
    /// series), reused if one exists. The caller `reload`s and `start`s it.
    func backgroundController(bookKey: String, title: String, bookURL: URL?, target: TranslationLanguage) -> (controller: TranslationController, isNew: Bool) {
        if let existing = (openBook + background).first(where: { $0.bookKey == bookKey && $0.target == target && $0.isConfigured }) {
            return (existing, false)
        }
        let controller = makeController(bookKey: bookKey, title: title, bookURL: bookURL)
        background.append(controller)
        return (controller, true)
    }

    // MARK: - Scheduling

    /// Run `controller`'s job now if nothing else is running, or queue it.
    /// The job for what's on screen jumps the queue.
    func start(_ controller: TranslationController) {
        // A background controller dropped while idle (an export holds on to
        // it between loading its cache and starting) has to be tracked again,
        // or a queued start would never be picked up.
        if !(openBook + background).contains(where: { $0 === controller }) {
            background.append(controller)
        }
        let others = (openBook + background).filter { $0 !== controller }
        if let running = others.first(where: \.isWorking) {
            guard controller === current else {
                controller.markQueued()
                return
            }
            isScheduling = true
            running.preempt()
            isScheduling = false
        }
        controller.start()
    }

    func pause(_ controller: TranslationController) {
        controller.pause()
    }

    /// Stop a job — or dismiss a failed one from the list.
    func stop(_ controller: TranslationController) {
        controller.stop()
        controller.notice = nil
        dropFinishedBackground()
    }

    /// Stop everything and delete the cache (Settings › Clear). Returns the
    /// bytes freed; the open book's controllers reload (empty) afterwards.
    func clearCache() async -> UInt64 {
        for controller in background { controller.clear() }
        background = []
        var removed: UInt64 = 0
        for controller in openBook {
            removed += await controller.clearCache()
        }
        if openBook.isEmpty {
            let store = store
            removed = await Task.detached(priority: .utility) { store.clear() }.value
        }
        return removed
    }

    /// Delete the model (Settings): jobs using it stop, and it's let go
    /// from memory.
    func deleteModel() async {
        for controller in openBook + background where controller.isWorking || controller.phase == .queued {
            controller.stop()
        }
        dropFinishedBackground()
        await (translator as? GemmaTranslator)?.unload()
        await model.remove()
    }

    // MARK: - Internals

    private func makeController(bookKey: String, title: String, bookURL: URL?) -> TranslationController {
        let controller = TranslationController(store: store, defaults: defaults, translator: translator, bookKey: bookKey, title: title, bookURL: bookURL)
        controller.makeAnalyzer = makeAnalyzer
        controller.onJobEnded = { [weak self] in self?.jobEnded() }
        controller.requestStart = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.start(controller)
        }
        return controller
    }

    /// Jobs that stopped for want of the model — in any book — start again.
    private func modelInstalled() {
        for controller in openBook + background where controller.notice == .needsModelDownload {
            controller.notice = nil
            start(controller)
        }
    }

    private func jobEnded() {
        guard !isScheduling else { return }
        // Defer: this runs inside the ending controller's own state change.
        Task { @MainActor [weak self] in
            self?.startNextQueued()
        }
    }

    private func startNextQueued() {
        dropFinishedBackground()
        let all = openBook + background
        guard !all.contains(where: \.isWorking) else { return }
        // On-screen job first; a queued job may have nothing left to do, so
        // move on until one actually runs.
        let queued = all.filter { $0.phase == .queued }
        for next in queued.sorted(by: { ($0 === current ? 0 : 1) < ($1 === current ? 0 : 1) }) {
            next.start()
            if next.isWorking { return }
        }
    }

    private func dropFinishedBackground() {
        background.removeAll { !Self.isWorthKeeping($0) }
    }

    private static func isWorthKeeping(_ controller: TranslationController) -> Bool {
        controller.hasActiveJob || controller.notice != nil
    }
}
