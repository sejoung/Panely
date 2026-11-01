import CoreGraphics
import Foundation
import Observation

/// Runs the translation assist for the open book.
///
/// The model (`GemmaTranslator`) takes ~0.25 s a balloon, a few seconds a
/// page, so a book can't be translated "instantly". The job is shaped so that
/// rarely matters while reading:
/// - **Stay ahead of the reader.** Work is cut into units (`TranslationPlan`)
///   and the next unit is always the first unfinished one at or after the
///   page on screen — paging ahead re-targets the job.
/// - **Show results as they come.** Balloons appear the moment OCR finds them
///   and fill in one translation at a time, as the model writes each line.
/// - **Translate in context.** A unit's balloons go to the model together,
///   up to `chunkSize` at a time, with the job's last `contextLines`
///   translations, so names, speakers and speech levels carry over.
/// - **Overlap the stages.** The next unit's OCR runs while the current
///   unit's balloons are being translated.
///
/// One controller per book. `TranslationManager` keeps a controller alive
/// after its book is closed while it still has work, so a job keeps running
/// in the background while another book is read, and reopening the book
/// reattaches to it. Only one job translates at a time; the manager queues
/// the rest.
///
/// Finished pages go to `TranslationStore`; reopening a book shows them at
/// once. Every settings change bumps `generation`, and work started under an
/// older generation never writes into the book's current state.
@Observable
@MainActor
final class TranslationController {
    nonisolated enum Phase: Equatable, Sendable {
        case idle
        case detectingLanguage
        /// Waiting for the first OCR result — loading models; slow (1–2 min)
        /// the first time a build runs.
        case preparing
        case translating
        case paused
        /// Waiting for another book's job to finish.
        case queued
    }

    /// Why a job couldn't start or stopped early. Shown in the status banner.
    nonisolated enum Notice: Equatable, Sendable {
        /// The translation model isn't downloaded yet.
        case needsModelDownload
        case couldNotDetectLanguage
        case failed(String)
        /// The job finished, but these pages didn't translate even on a retry.
        case pagesFailed(Int)

        func message(locale: Locale) -> String {
            switch self {
            case .needsModelDownload:
                return String(localized: "Download the translation model to translate.", bundle: .localized)
            case .couldNotDetectLanguage:
                return String(localized: "Couldn't tell which language this book is in. Choose it in the translation panel.", bundle: .localized)
            case let .failed(reason):
                return String(localized: "Translation stopped: \(reason)", bundle: .localized)
            case let .pagesFailed(count):
                return String(localized: "Couldn't translate \(count) pages. Translate again to retry them.", bundle: .localized)
            }
        }
    }

    /// Translations for the open book, keyed by `ComicPage.id`. Includes
    /// pages still in progress. Written through `setPage`/`removeAllPages`,
    /// which keep `hasPages` and `pageRevisions` in step.
    private(set) var pages: [String: TranslatedPage] = [:]
    /// `!pages.isEmpty`, observed on its own: `pages` changes with every
    /// balloon translated, and views that only ask whether there's anything
    /// (toolbar, menus) shouldn't re-render each time.
    private(set) var hasPages = false
    /// A number that changes whenever a page's entry in `pages` does, unique
    /// across controllers — lets the viewer keep what it built from a page
    /// until the page changes (`ReaderViewModel.translationOverlayPages`).
    @ObservationIgnored private(set) var pageRevisions: [String: Int] = [:]
    private static var nextPageRevision = 0
    /// The revision of the latest write to `pages`.
    @ObservationIgnored private(set) var pagesStamp = 0
    /// Which pages recent writes touched, so a reader of a whole book's pages
    /// can look at just those (`pagesChanged(since:)`). Holds every write after
    /// `pageChangeFloor`.
    @ObservationIgnored private var pageChanges: [(stamp: Int, id: String)] = []
    @ObservationIgnored private var pageChangeFloor = 0
    private static let maxPageChanges = 512
    private(set) var phase: Phase = .idle
    /// Indices of pages whose translation is complete (cached or finished).
    private(set) var completedPageIndices: Set<Int> = []
    /// The book's language — the series' remembered one, or detected on the
    /// first start. `nil` until known.
    private(set) var source: TranslationLanguage?
    /// Measured pace of the running job, for the time estimate.
    private(set) var secondsPerPage: Double?
    /// True until a job has produced its first OCR result under this build —
    /// the case where model loading takes a minute or two.
    private(set) var isFirstRunForThisBuild: Bool
    var notice: Notice?
    /// OCR has kept the job waiting for a while. The system sometimes spends
    /// tens of seconds preparing a model mid-book, which otherwise looks stuck.
    private(set) var isWaitingForOCR = false

    let store: TranslationStore
    /// The book this controller translates (its file or folder path) and a
    /// display title; empty for the placeholder shown while no book is open.
    let bookKey: String
    let title: String
    /// The book's file or folder, to reopen it from the jobs list.
    let bookURL: URL?
    /// Called when a language was detected, so it can be remembered for the series.
    @ObservationIgnored var onSourceDetected: ((TranslationLanguage) -> Void)?
    /// Asked for the book's language when a job starts without one — a queued
    /// volume picks up what an earlier volume of the series detected.
    @ObservationIgnored var sourceResolver: (() -> TranslationLanguage?)?
    /// Called whenever a job stops running (finished, paused, stopped, failed),
    /// so the manager can start the next queued one.
    @ObservationIgnored var onJobEnded: (() -> Void)?
    /// How an automatic start (auto-translate, resuming after a language
    /// change) asks to run — through the manager's queue.
    @ObservationIgnored var requestStart: (() -> Void)?
    /// The book's pages only exist while it's open — an archive inside an
    /// archive, unpacked to a temporary folder that's deleted when the reader
    /// moves on. Such a job pauses when its book closes instead of failing.
    @ObservationIgnored var requiresOpenBook = false
    /// Paused because its book (which `requiresOpenBook`) was closed; resumes
    /// only once the book is open again.
    private(set) var isWaitingForBookToReopen = false

    /// Security-scoped URLs (library folder, the book) the job holds open while
    /// it runs, so it keeps reading pages after the reader moves elsewhere and
    /// releases its own grant.
    @ObservationIgnored var accessURLs: [URL] = []
    @ObservationIgnored private var accessedURLs: [URL] = []

    @ObservationIgnored private let defaults: any KeyValueStoring
    @ObservationIgnored private var bookPages: [ComicPage] = []
    /// The book's page sizes (strip scope): handed in, or read by the first
    /// job that needs them and kept for the next.
    @ObservationIgnored private(set) var pageSizes: [CGSize] = []
    /// The language this controller translates into (one controller per book
    /// and language — see `TranslationManager`).
    @ObservationIgnored private(set) var target: TranslationLanguage = .english
    /// Set by the first `reload`; until then `target` is only a default.
    @ObservationIgnored private(set) var isConfigured = false
    @ObservationIgnored private(set) var scope: TranslationScope = .page
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var plan: TranslationPlan?
    @ObservationIgnored private var finishedUnits: Set<Int> = []
    /// Units that failed; their pages aren't cached, so they retry next time.
    @ObservationIgnored private var failedUnits: Set<Int> = []
    /// Units that failed once and go round again after everything else: the
    /// OCR's failures have been passing ones.
    @ObservationIgnored private var unitsToRetry: Set<Int> = []
    @ObservationIgnored private var focusPage = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var jobTask: Task<Void, Never>?
    /// Readable so tests can await the cache load instead of sleeping.
    @ObservationIgnored private(set) var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var translatingSince: Date?
    @ObservationIgnored private var pagesCompletedThisJob = 0
    /// Translates the balloons — the app's one `GemmaTranslator`; tests hand
    /// in stand-ins.
    @ObservationIgnored let translator: any BalloonTranslating
    /// Reads a unit's balloons; `nil` is OCR (`PageAnalyzer`). Tests hand
    /// balloons to a job through this.
    @ObservationIgnored var makeAnalyzer: (@Sendable ([ComicPage], TranslationLanguage) -> any PageAnalyzing)?

    nonisolated static let maxConsecutiveFailures = 3
    /// How long OCR may keep a job waiting before the status says so.
    @ObservationIgnored var ocrWaitNoticeDelay: Duration = .seconds(5)
    /// Units read ahead of the one being translated. A page takes the model
    /// a few seconds; two pages of OCR in flight keep it fed without OCR
    /// running far ahead of a reader who jumps around.
    nonisolated static let lookahead = 2
    /// Balloons per request. Pages rarely have more, and longer prompts
    /// make the first line of a request wait longer.
    nonisolated static let chunkSize = 16
    /// Translations already made that go along with each request.
    nonisolated static let contextLines = 6
    nonisolated static let warmedUpBuildKey = "panely.translation.warmedUpBuild"

    init(
        store: TranslationStore,
        defaults: any KeyValueStoring = LiveKeyValueStore(),
        translator: any BalloonTranslating = GemmaTranslator.shared,
        bookKey: String = "",
        title: String = "",
        bookURL: URL? = nil
    ) {
        self.store = store
        self.defaults = defaults
        self.translator = translator
        self.bookKey = bookKey
        self.title = title
        self.bookURL = bookURL
        isFirstRunForThisBuild = defaults.dictionaryRepresentation()[Self.warmedUpBuildKey] as? String != Self.buildIdentifier
    }

    nonisolated static var isSupportedOnThisMac: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    nonisolated static var buildIdentifier: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] ?? "")-\(info?["CFBundleVersion"] ?? "")"
    }

    var isWorking: Bool {
        switch phase {
        case .detectingLanguage, .preparing, .translating: true
        case .idle, .paused, .queued: false
        }
    }

    /// Has a job in progress, waiting or paused — worth keeping alive when
    /// its book is closed.
    var hasActiveJob: Bool { phase != .idle }

    var bookPageCount: Int { bookPages.count }
    var completedPageCount: Int { completedPageIndices.count }

    /// Estimated time left for the untranslated pages, once there's a pace.
    var remainingSeconds: Double? {
        guard let secondsPerPage, phase == .translating else { return nil }
        return Double(bookPages.count - completedPageIndices.count) * secondsPerPage
    }

    // MARK: - Book / settings changes

    /// Drop the open book's state right away (book switch), before the new
    /// book is known well enough to `reload`.
    func clear() {
        stopJob(to: .idle)
        cacheTask?.cancel()
        cacheTask = nil
        generation &+= 1
        bookPages = []
        pageSizes = []
        removeAllPages()
        completedPageIndices = []
        plan = nil
        finishedUnits = []
        failedUnits = []
        unitsToRetry = []
        isWaitingForOCR = false
        secondsPerPage = nil
        notice = nil
    }

    /// Set up for a book: pick up cached translations for this language pair
    /// and scope, and start a job right away when `autoStart`.
    func reload(
        pages bookPages: [ComicPage],
        pageSizes: [CGSize],
        scope: TranslationScope,
        source: TranslationLanguage?,
        target: TranslationLanguage,
        enabled: Bool,
        autoStart: Bool,
        focusPage: Int
    ) {
        clear()
        isConfigured = true
        self.bookPages = enabled ? bookPages : []
        self.pageSizes = pageSizes.count == bookPages.count ? pageSizes : []
        self.scope = scope
        self.source = source
        self.target = target
        self.enabled = enabled
        self.focusPage = focusPage
        guard enabled, !bookPages.isEmpty else { return }

        let generation = generation
        cacheTask = Task { [weak self] in
            if let source {
                await self?.loadCache(source: source, generation: generation)
            }
            guard let self, self.generation == generation else { return }
            if autoStart {
                if let requestStart = self.requestStart { requestStart() } else { self.start() }
            }
        }
    }

    /// The page being read; the job works outward from here.
    func setFocus(_ page: Int) {
        focusPage = page
    }

    /// Change the book's language (user choice in the panel).
    func setSource(_ language: TranslationLanguage) {
        guard language != source else { return }
        // Having told the reader to choose the language, get on with it once
        // they have.
        let wasWorking = isWorking || phase == .paused || notice == .couldNotDetectLanguage
        reload(
            pages: bookPages,
            pageSizes: pageSizes,
            scope: scope,
            source: language,
            target: target,
            enabled: enabled,
            autoStart: wasWorking,
            focusPage: focusPage
        )
    }

    // MARK: - Jobs

    /// Start (or resume) translating the rest of the book. Call through
    /// `TranslationManager.start(_:)`, which keeps one job running at a time.
    func start() {
        guard #available(macOS 26.0, *) else { return }
        guard !isWorking, !isWaitingForBookToReopen else { return }
        guard enabled, !bookPages.isEmpty, completedPageIndices.count < bookPages.count else {
            // Nothing to do (e.g. a queued book finished meanwhile): don't sit
            // in the queue.
            phase = .idle
            return
        }
        notice = nil
        if source == nil, let resolved = sourceResolver?() {
            source = resolved
        }
        acquireAccess()
        jobTask = makeJob()
    }

    /// Wait for another job; `start()` runs it later.
    func markQueued() {
        guard !isWorking, enabled, completedPageIndices.count < bookPages.count else { return }
        phase = .queued
    }

    /// Make way for another job, resuming later.
    func preempt() {
        guard isWorking else { return }
        stopJob(to: .queued)
    }

    /// Stop but keep progress on screen, ready to resume.
    func pause() {
        guard isWorking || phase == .queued else { return }
        stopJob(to: .paused)
    }

    func stop() {
        stopJob(to: .idle)
    }

    /// The book closed and its pages are about to disappear.
    func pauseUntilBookReopens() {
        guard hasActiveJob else { return }
        if phase != .paused { stopJob(to: .paused) }
        isWaitingForBookToReopen = true
    }

    /// The book is open again.
    func bookReopened() {
        isWaitingForBookToReopen = false
    }

    /// Throw away what `pageIndices` were translated to — on screen and in
    /// the cache — and translate them again, starting from the first: pages
    /// translated before an analysis improved (balloons found by the
    /// detector) get it without clearing the whole
    /// cache. In strip scope the bands covering them are read again; pages
    /// already done that share a band keep their results.
    func translateAgain(pageIndices: Set<Int>) async {
        // Results still loading from the cache would land after this.
        await cacheTask?.value
        let indices = pageIndices.filter { bookPages.indices.contains($0) }
        guard enabled, let source, !indices.isEmpty else { return }
        stopJob(to: .idle)
        // Work started for the old results mustn't write into the new ones.
        generation &+= 1
        notice = nil

        var ids: [String] = []
        for index in indices {
            let id = bookPages[index].id
            setPage(nil, for: id)
            completedPageIndices.remove(index)
            ids.append(id)
        }
        plan = nil
        finishedUnits = []
        failedUnits = []
        unitsToRetry = []
        isWaitingForOCR = false
        focusPage = indices.min() ?? focusPage
        let store = store
        let target = target
        let scope = scope
        await Task.detached(priority: .utility) {
            store.remove(keys: ids.map { TranslationStore.key(pageID: $0, from: source, to: target, scope: scope) })
        }.value
        AppLog.info(.reader, "Translating pages again", metadata: ["pages": "\(indices.count)"])
        if let requestStart { requestStart() } else { start() }
    }

    /// Delete every cached translation (all books). The open book's overlays
    /// go too — they'd otherwise outlive their cache entries.
    func clearCache() async -> UInt64 {
        let snapshot = (bookPages, pageSizes, scope, source, target, enabled, focusPage)
        clear()
        let store = store
        let removed = await Task.detached(priority: .utility) { store.clear() }.value
        reload(
            pages: snapshot.0, pageSizes: snapshot.1, scope: snapshot.2, source: snapshot.3, target: snapshot.4,
            enabled: snapshot.5, autoStart: false, focusPage: snapshot.6
        )
        return removed
    }

    /// Reading order for language detection: from the page on screen to the
    /// end, then the pages before it.
    nonisolated static func translationOrder(count: Int, startingAt start: Int) -> [Int] {
        guard count > 0 else { return [] }
        let start = min(max(0, start), count - 1)
        return Array(start..<count) + Array(0..<start)
    }

    private func stopJob(to newPhase: Phase) {
        let wasRunning = jobTask != nil
        jobTask?.cancel()
        jobTask = nil
        phase = newPhase
        translatingSince = nil
        isWaitingForOCR = false
        releaseAccess()
        // Balloons left mid-flight stay pending; a resumed job redoes their unit.
        if wasRunning { onJobEnded?() }
    }

    private func acquireAccess() {
        releaseAccess()
        accessedURLs = accessURLs.filter { $0.startAccessingSecurityScopedResource() }
    }

    private func releaseAccess() {
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
        accessedURLs = []
    }

    @available(macOS 26.0, *)
    private func makeJob() -> Task<Void, Never> {
        let generation = generation
        let bookPages = bookPages
        let knownSizes = pageSizes
        let scope = scope
        let knownSource = source
        let target = target
        let focus = focusPage
        let translator = translator
        let makeAnalyzer = makeAnalyzer
        let ocrWaitNoticeDelay = ocrWaitNoticeDelay
        phase = knownSource == nil ? .detectingLanguage : .preparing
        AppLog.info(.reader, "Translation started", metadata: [
            "pages": "\(bookPages.count)", "scope": "\(scope.rawValue)", "target": "\(target.rawValue)",
        ])

        // Detached: decoding, OCR and sampling are CPU work that must stay
        // off the main actor while the user keeps reading.
        return Task.detached(priority: .utility) { [weak self] in
            // 1. Language
            var source = knownSource
            if source == nil {
                source = await TranslationLanguageDetector.detect(in: bookPages, startingAt: focus)
                guard let detected = source else {
                    await self?.finishJob(generation: generation, notice: .couldNotDetectLanguage)
                    return
                }
                await self?.didDetect(detected, generation: generation)
                await self?.loadCache(source: detected, generation: generation)
            }
            guard let source, !Task.isCancelled else { return }

            // 2. Model — loaded while OCR reads the first page.
            guard translator.isReady() else {
                await self?.finishJob(generation: generation, notice: .needsModelDownload)
                return
            }
            let preparing = Task { try await translator.prepare() }

            // 3. Plan
            let plan: TranslationPlan
            if scope == .strip {
                var sizes = knownSizes
                if sizes.count != bookPages.count {
                    sizes = await Self.readPageSizes(of: bookPages)
                    guard !Task.isCancelled else {
                        preparing.cancel()
                        return
                    }
                    await self?.rememberPageSizes(sizes, generation: generation)
                }
                plan = .strip(StripLayout(pageSizes: sizes))
            } else {
                plan = .pages(count: bookPages.count)
            }
            guard await self?.adopt(plan, generation: generation) == true else {
                preparing.cancel()
                return
            }

            // 4. Work: OCR the next units while translating the current one.
            let analyzer = makeAnalyzer?(bookPages, source) ?? PageAnalyzer(pages: bookPages, language: source)
            var consecutiveFailures = 0
            var lastError: (any Error)?
            // Text seen earlier in the book ("하치켄!", a recurring sign) is
            // reused instead of translated again.
            var translatedTexts: [String: String] = [:]
            // The job's latest translations, in the order made: the context
            // for the next request.
            var recent: [TranslationContextLine] = []
            var stats = TranslationJobStats()
            defer { AppLog.info(.reader, "Translation job stats", metadata: stats.metadata) }

            var lookahead: [(unit: TranslationUnit, analysis: Task<[PageAnalysis], any Error>)] = []
            func fillLookahead(excluding current: Int?) async {
                // A paused job mustn't start more OCR on its way out.
                while lookahead.count < Self.lookahead, !Task.isCancelled {
                    let inFlight = Set(lookahead.map(\.unit.id) + [current].compactMap { $0 })
                    guard let unit = await self?.claimNextUnit(excluding: inFlight, generation: generation) else { return }
                    lookahead.append((unit, Task { try await analyzer.analyze(unit, plan: plan) }))
                }
            }
            func cancelLookahead() {
                preparing.cancel()
                for entry in lookahead { entry.analysis.cancel() }
            }
            func publish(_ translations: [TranslationPublication]) async {
                guard !translations.isEmpty else { return }
                let start = ContinuousClock.now
                // One hop for the lot: each is a change the viewer redraws for.
                await self?.setTranslations(translations, generation: generation)
                stats.publishing += start.duration(to: .now)
            }
            func publish(_ translation: String, to balloons: [(pageIndex: Int, bubbleID: Int)]) async {
                await publish(balloons.map { TranslationPublication(text: translation, pageIndex: $0.pageIndex, bubbleID: $0.bubbleID) })
            }

            await fillLookahead(excluding: nil)
            while !lookahead.isEmpty {
                guard !Task.isCancelled else {
                    cancelLookahead()
                    return
                }
                let (unit, analysisTask) = lookahead.removeFirst()
                var unitFailed = false
                do {
                    let waitStart = ContinuousClock.now
                    // The analyses are tasks of their own, which cancelling
                    // the job doesn't reach: pausing passes it on, so OCR
                    // stops with the job instead of running to the end.
                    let pending = lookahead.map(\.analysis)
                    let waitingNotice = Task { [weak self] in
                        try await Task.sleep(for: ocrWaitNoticeDelay)
                        await self?.setWaitingForOCR(true, generation: generation)
                    }
                    defer { waitingNotice.cancel() }
                    let analyses = try await withTaskCancellationHandler {
                        try await analysisTask.value
                    } onCancel: {
                        analysisTask.cancel()
                        for task in pending { task.cancel() }
                    }
                    waitingNotice.cancel()
                    await self?.setWaitingForOCR(false, generation: generation)
                    // Finished regardless (or had nothing to cancel): the
                    // unit is left for the resumed job, not marked done.
                    try Task.checkCancellation()
                    stats.analysisWait += waitStart.duration(to: .now)
                    let queue = await self?.merge(analyses, generation: generation) ?? []
                    // Prefetch: the next units' OCR overlaps this unit's translation.
                    await fillLookahead(excluding: unit.id)

                    // Each text once, in reading order; balloons repeating it
                    // (here or earlier in the book) take the same translation.
                    var waiting: [String: [(pageIndex: Int, bubbleID: Int)]] = [:]
                    var texts: [String] = []
                    var reused: [TranslationPublication] = []
                    for item in queue {
                        if let known = translatedTexts[item.source] {
                            stats.reused += 1
                            reused.append(TranslationPublication(text: known, pageIndex: item.pageIndex, bubbleID: item.bubbleID))
                        } else if waiting[item.source] != nil {
                            stats.reused += 1
                            waiting[item.source]?.append((item.pageIndex, item.bubbleID))
                        } else {
                            waiting[item.source] = [(item.pageIndex, item.bubbleID)]
                            texts.append(item.source)
                        }
                    }
                    await publish(reused)
                    // Nothing new on this unit: no need to wait for the model.
                    if !texts.isEmpty {
                        let prepareStart = ContinuousClock.now
                        try await preparing.value
                        stats.preparing += prepareStart.duration(to: .now)
                        for start in stride(from: 0, to: texts.count, by: Self.chunkSize) {
                            let chunk = Array(texts[start..<min(start + Self.chunkSize, texts.count)])
                            let translateStart = ContinuousClock.now
                            var answered = Set<String>()
                            let lines = translator.translate(chunk, context: Array(recent.suffix(Self.contextLines)), from: source, to: target)
                            for try await line in lines where chunk.indices.contains(line.index) {
                                let text = chunk[line.index]
                                guard answered.insert(text).inserted else { continue }
                                translatedTexts[text] = line.text
                                recent.append(TranslationContextLine(source: text, translation: line.text))
                                await publish(line.text, to: waiting[text] ?? [])
                            }
                            try Task.checkCancellation()
                            stats.translating += translateStart.duration(to: .now)
                            stats.translated += chunk.count
                            // The model never answered these: shown as balloons
                            // that couldn't be translated, and asked again
                            // should the text come up later.
                            for text in chunk where !answered.contains(text) {
                                stats.unanswered += 1
                                await publish("", to: waiting[text] ?? [])
                            }
                            recent = Array(recent.suffix(Self.contextLines))
                        }
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        cancelLookahead()
                        return
                    }
                    AppLog.error(.reader, "Translation unit failed", metadata: ["unit": "\(unit.id)", "error": "\(error)"])
                    lastError = error
                    unitFailed = true
                    await self?.setWaitingForOCR(false, generation: generation)
                    await fillLookahead(excluding: unit.id)
                }
                await self?.finishUnit(unit.id, failed: unitFailed, generation: generation)
                stats.units += 1
                // A unit going round again, when nothing else is left to claim.
                if unitFailed { await fillLookahead(excluding: nil) }
                consecutiveFailures = unitFailed ? consecutiveFailures + 1 : 0
                if consecutiveFailures >= Self.maxConsecutiveFailures {
                    cancelLookahead()
                    // The model went missing (deleted in Settings, say).
                    let notice: Notice = translator.isReady() ? .failed(lastError?.localizedDescription ?? "") : .needsModelDownload
                    await self?.finishJob(generation: generation, notice: notice)
                    return
                }
            }
            if !Task.isCancelled {
                await self?.finishJob(generation: generation, notice: nil)
            }
        }
    }

    // MARK: - Job callbacks (main actor)

    private func loadCache(source: TranslationLanguage, generation: Int) async {
        let store = store
        let target = target
        let scope = scope
        let ids = bookPages.map(\.id)
        // Hashing every page's key is work too: all of it off the main actor.
        let entries = await Task.detached(priority: .utility) {
            // One directory listing instead of a failed open per missing entry.
            let existing = store.existingKeys()
            guard !existing.isEmpty else { return [(index: Int, key: String)]() }
            return ids.enumerated().compactMap { index, id -> (index: Int, key: String)? in
                let key = TranslationStore.key(pageID: id, from: source, to: target, scope: scope)
                return existing.contains(key) ? (index, key) : nil
            }
        }.value
        let keys = Dictionary(entries.map { ($0.index, $0.key) }, uniquingKeysWith: { first, _ in first })
        // Reading a long book takes a while; the pages being read shouldn't
        // wait for the rest of it.
        for batch in Self.cacheLoadBatches(indices: entries.map(\.index), focus: focusPage) {
            guard self.generation == generation else { return }
            let batchKeys = batch.compactMap { index in keys[index].map { (index, $0) } }
            let cached = await Task.detached(priority: .utility) {
                batchKeys.compactMap { index, key -> (Int, TranslatedPage)? in
                    guard let page = store.load(key: key), page.isComplete else { return nil }
                    return (index, page)
                }
            }.value
            guard self.generation == generation else { return }
            var loaded: [(String, TranslatedPage)] = []
            var completed = completedPageIndices
            for (index, page) in cached where pages[ids[index]]?.isComplete != true {
                loaded.append((ids[index], page))
                completed.insert(index)
            }
            guard !loaded.isEmpty else { continue }
            setPages(loaded)
            completedPageIndices = completed
        }
    }

    /// Pages of the first batch: about what can be on screen around the focus.
    nonisolated static let firstCacheBatch = 8
    nonisolated static let cacheBatch = 200

    /// `indices` nearest `focus` first, in batches: a small one for what's on
    /// screen, then larger ones so the rest doesn't redraw the viewer per page.
    nonisolated static func cacheLoadBatches(indices: [Int], focus: Int) -> [[Int]] {
        let ordered = indices.sorted {
            let (a, b) = (abs($0 - focus), abs($1 - focus))
            return a != b ? a < b : $0 > $1
        }
        guard ordered.count > firstCacheBatch else { return ordered.isEmpty ? [] : [ordered] }
        return [Array(ordered.prefix(firstCacheBatch))] + stride(from: firstCacheBatch, to: ordered.count, by: cacheBatch).map {
            Array(ordered[$0..<min($0 + cacheBatch, ordered.count)])
        }
    }

    /// Reads at most this many pages' headers at once: enough to get through
    /// a folder quickly, without flooding the disk or the archive's actor.
    nonisolated static let concurrentSizeReads = 8

    /// The pages' sizes, in page order; `.zero` for a page that can't be read.
    @concurrent
    nonisolated static func readPageSizes(of pages: [ComicPage]) async -> [CGSize] {
        var sizes = [CGSize](repeating: .zero, count: pages.count)
        await withTaskGroup(of: (Int, CGSize).self) { group in
            for (index, page) in pages.enumerated() {
                if index >= concurrentSizeReads, let (done, size) = await group.next() {
                    sizes[done] = size
                }
                group.addTask { (index, (try? await ImageLoader.dimensions(for: page)) ?? .zero) }
            }
            for await (done, size) in group {
                sizes[done] = size
            }
        }
        return sizes
    }

    /// Keep what a job read for the next: pausing and resuming would otherwise
    /// read every page's header again. Not with a page that couldn't be read —
    /// the next job tries it again, as it would have.
    private func rememberPageSizes(_ sizes: [CGSize], generation: Int) {
        guard self.generation == generation, sizes.count == bookPages.count, !sizes.contains(.zero) else { return }
        pageSizes = sizes
    }

    // MARK: - Pages

    /// Every write to `pages` goes through here (and `setPages` /
    /// `removeAllPages`), so `hasPages` and `pageRevisions` follow it.
    private func setPage(_ page: TranslatedPage?, for id: String) {
        pages[id] = page
        let revision = Self.makePageRevision()
        pageRevisions[id] = page == nil ? nil : revision
        notePageChange(id, revision: revision)
        updateHasPages()
    }

    /// Several pages in one write — one change for observers.
    private func setPages(_ changes: [(String, TranslatedPage)]) {
        guard !changes.isEmpty else { return }
        var updated = pages
        for (id, page) in changes {
            updated[id] = page
            let revision = Self.makePageRevision()
            pageRevisions[id] = revision
            notePageChange(id, revision: revision)
        }
        pages = updated
        updateHasPages()
    }

    private func removeAllPages() {
        if !pages.isEmpty { pages = [:] }
        pageRevisions = [:]
        // Everything changed: no list of pages says so.
        pagesStamp = Self.makePageRevision()
        pageChanges = []
        pageChangeFloor = pagesStamp
        updateHasPages()
    }

    private func notePageChange(_ id: String, revision: Int) {
        pagesStamp = revision
        pageChanges.append((revision, id))
        if pageChanges.count > Self.maxPageChanges {
            let dropped = Self.maxPageChanges / 2
            pageChangeFloor = pageChanges[dropped - 1].stamp
            pageChanges.removeFirst(dropped)
        }
    }

    /// The pages written since `stamp` (an earlier `pagesStamp`); `nil` when
    /// that's too long ago to say, or everything changed.
    func pagesChanged(since stamp: Int) -> Set<String>? {
        guard stamp >= pageChangeFloor else { return nil }
        var changed = Set<String>()
        for change in pageChanges.reversed() {
            guard change.stamp > stamp else { break }
            changed.insert(change.id)
        }
        return changed
    }

    private func updateHasPages() {
        // Only on a flip: observers of `hasPages` don't care about the rest.
        if hasPages == pages.isEmpty { hasPages = !pages.isEmpty }
    }

    private static func makePageRevision() -> Int {
        nextPageRevision &+= 1
        return nextPageRevision
    }

    private func didDetect(_ language: TranslationLanguage, generation: Int) {
        guard self.generation == generation else { return }
        source = language
        phase = .preparing
        onSourceDetected?(language)
        AppLog.info(.reader, "Translation language detected", metadata: ["language": "\(language.rawValue)"])
    }

    private func adopt(_ plan: TranslationPlan, generation: Int) -> Bool {
        guard self.generation == generation else { return false }
        self.plan = plan
        finishedUnits = plan.unitsAlreadyDone(completePages: completedPageIndices)
        failedUnits = []
        unitsToRetry = []
        pagesCompletedThisJob = 0
        // Balloons a failed job blanked so they'd stop pulsing: this job asks
        // for them again. (Complete pages keep theirs: the model really left
        // those empty.)
        for (index, page) in bookPages.enumerated() where !completedPageIndices.contains(index) {
            guard var translated = pages[page.id], translated.bubbles.contains(where: { $0.translation == "" }) else { continue }
            for bubble in translated.bubbles.indices where translated.bubbles[bubble].translation == "" {
                translated.bubbles[bubble].translation = nil
            }
            setPage(translated, for: page.id)
        }
        return true
    }

    private func claimNextUnit(excluding inFlight: Set<Int>, generation: Int) -> TranslationUnit? {
        guard self.generation == generation, let plan else { return nil }
        let unavailable = finishedUnits.union(inFlight)
        return plan.nextUnit(excluding: unavailable.union(unitsToRetry), focusPage: focusPage)
            ?? plan.nextUnit(excluding: unavailable, focusPage: focusPage)
    }

    private func setWaitingForOCR(_ waiting: Bool, generation: Int) {
        guard self.generation == generation, isWaitingForOCR != waiting else { return }
        isWaitingForOCR = waiting
    }

    /// Fold a unit's balloons into the pages; returns the balloons still to
    /// translate, in reading order.
    private func merge(_ analyses: [PageAnalysis], generation: Int) -> [(pageIndex: Int, bubbleID: Int, source: String)] {
        guard self.generation == generation else { return [] }
        if phase == .preparing {
            phase = .translating
            translatingSince = Date()
            if isFirstRunForThisBuild {
                isFirstRunForThisBuild = false
                defaults.set(Self.buildIdentifier, forKey: Self.warmedUpBuildKey)
            }
        }
        var queue: [(pageIndex: Int, bubbleID: Int, source: String)] = []
        for analysis in analyses.sorted(by: { $0.pageIndex < $1.pageIndex }) where bookPages.indices.contains(analysis.pageIndex) {
            guard !completedPageIndices.contains(analysis.pageIndex) else { continue }
            let id = bookPages[analysis.pageIndex].id
            var page = pages[id] ?? TranslatedPage(
                imageWidth: analysis.imageSize.width,
                imageHeight: analysis.imageSize.height,
                bubbles: [],
                isComplete: false
            )
            // A resumed job redoes a unit whose balloons may already be here.
            let known = Set(page.bubbles.map(\.source))
            for var bubble in analysis.bubbles.sorted(by: { $0.rect.minY < $1.rect.minY }) where !known.contains(bubble.source) {
                bubble.id = (page.bubbles.map(\.id).max() ?? -1) + 1
                page.bubbles.append(bubble)
            }
            for bubble in page.bubbles where bubble.translation == nil {
                queue.append((analysis.pageIndex, bubble.id, bubble.source))
            }
            setPage(page, for: id)
        }
        return queue
    }

    /// Fill balloons in, each page written once however many of its balloons
    /// changed.
    private func setTranslations(_ translations: [TranslationPublication], generation: Int) {
        guard self.generation == generation else { return }
        for (pageIndex, group) in Dictionary(grouping: translations, by: \.pageIndex) where bookPages.indices.contains(pageIndex) {
            let id = bookPages[pageIndex].id
            guard var page = pages[id] else { continue }
            var changed = false
            for translation in group {
                guard let index = page.bubbles.firstIndex(where: { $0.id == translation.bubbleID }) else { continue }
                page.bubbles[index].translation = translation.text
                changed = true
            }
            if changed { setPage(page, for: id) }
        }
    }

    private func finishUnit(_ unitID: Int, failed: Bool, generation: Int) {
        guard self.generation == generation, let plan else { return }
        if failed, unitsToRetry.insert(unitID).inserted {
            // Not finished: `claimNextUnit` hands it out again once the others
            // are done. Its balloons keep pulsing until then.
            AppLog.info(.reader, "Translation unit will be retried", metadata: ["unit": "\(unitID)"])
            return
        }
        finishedUnits.insert(unitID)
        if failed, let unit = plan.units.first(where: { $0.id == unitID }) {
            failedUnits.insert(unitID)
            // Stop the failed unit's balloons pulsing as "pending" forever;
            // its pages aren't cached (below), so they're retried next time.
            for index in unit.pageIndices where bookPages.indices.contains(index) {
                let id = bookPages[index].id
                guard var page = pages[id] else { continue }
                for bubbleIndex in page.bubbles.indices where page.bubbles[bubbleIndex].translation == nil {
                    page.bubbles[bubbleIndex].translation = ""
                }
                setPage(page, for: id)
            }
        }
        let failedPages = Set(plan.units.filter { failedUnits.contains($0.id) }.flatMap(\.pageIndices))
        let newlyComplete = plan.completedPages(finishedUnits: finishedUnits).subtracting(completedPageIndices)
        var toSave: [(String, TranslatedPage)] = []
        for index in newlyComplete.sorted() where bookPages.indices.contains(index) {
            let id = bookPages[index].id
            var page = pages[id] ?? TranslatedPage(
                imageWidth: Double(plan.layout?.pageSizes[index].width ?? 0),
                imageHeight: Double(plan.layout?.pageSizes[index].height ?? 0),
                bubbles: []
            )
            guard page.pendingCount == 0 else { continue }
            // Left incomplete, so translating again picks up just these pages.
            guard !failedPages.contains(index) else { continue }
            page.isComplete = true
            setPage(page, for: id)
            completedPageIndices.insert(index)
            pagesCompletedThisJob += 1
            if let source, page.imageWidth > 0 {
                toSave.append((TranslationStore.key(pageID: id, from: source, to: target, scope: scope), page))
            }
        }
        if let translatingSince, pagesCompletedThisJob > 0 {
            secondsPerPage = Date().timeIntervalSince(translatingSince) / Double(pagesCompletedThisJob)
        }
        guard !toSave.isEmpty else { return }
        let store = store
        Task.detached(priority: .utility) {
            for (key, page) in toSave { try? store.save(page, key: key) }
        }
    }

    private var failedPagesNotice: Notice? {
        guard let plan, !failedUnits.isEmpty else { return nil }
        let pages = plan.units.filter { failedUnits.contains($0.id) }.flatMap(\.pageIndices)
        return .pagesFailed(Set(pages).subtracting(completedPageIndices).count)
    }

    private func finishJob(generation: Int, notice: Notice?) {
        guard self.generation == generation else { return }
        jobTask = nil
        phase = .idle
        translatingSince = nil
        isWaitingForOCR = false
        releaseAccess()
        self.notice = notice ?? failedPagesNotice
        AppLog.info(.reader, "Translation finished", metadata: ["notice": "\(String(describing: self.notice))"])
        onJobEnded?()
    }
}

/// A translation on its way to a balloon.
private nonisolated struct TranslationPublication: Sendable {
    let text: String
    let pageIndex: Int
    let bubbleID: Int
}

/// Where a job's time went, logged when it ends — translating should be
/// nearly all of it; the rest is loading the model, waiting for OCR or for
/// the main actor.
private nonisolated struct TranslationJobStats {
    let started = ContinuousClock.now
    var units = 0
    var translated = 0
    var reused = 0
    /// Balloons the model never answered.
    var unanswered = 0
    var translating: Duration = .zero
    var preparing: Duration = .zero
    var analysisWait: Duration = .zero
    var publishing: Duration = .zero

    var metadata: AppLog.Metadata {
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        func format(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }
        return [
            "units": "\(units)", "translated": "\(translated)", "reused": "\(reused)",
            "wallSeconds": "\(format(seconds(started.duration(to: .now))))",
            "unanswered": "\(unanswered)",
            "translatingSeconds": "\(format(seconds(translating)))",
            "preparingSeconds": "\(format(seconds(preparing)))",
            "analysisWaitSeconds": "\(format(seconds(analysisWait)))",
            "publishingSeconds": "\(format(seconds(publishing)))",
            "secondsPerBalloon": "\(format(translated > 0 ? seconds(translating) / Double(translated) : 0, 2))",
        ]
    }
}
