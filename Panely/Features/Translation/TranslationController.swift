import CoreGraphics
import Foundation
import Observation

/// Runs the translation assist for the open book.
///
/// Apple Translation handles one sentence at a time (~1 s each, however it's
/// called — measured), so a book can't be translated "instantly". The job is
/// shaped so that rarely matters while reading:
/// - **Stay ahead of the reader.** Work is cut into units (`TranslationPlan`)
///   and the next unit is always the first unfinished one at or after the
///   page on screen — paging ahead re-targets the job.
/// - **Show results as they come.** Balloons appear the moment OCR finds them
///   and fill in one translation at a time.
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
        case needsLanguageDownload(TranslationLanguage, TranslationLanguage)
        case unsupportedPair(TranslationLanguage, TranslationLanguage)
        case couldNotDetectLanguage
        case failed(String)

        func message(locale: Locale) -> String {
            switch self {
            case let .needsLanguageDownload(source, target):
                let from = source.displayName(in: locale)
                let to = target.displayName(in: locale)
                return String(localized: "Download the \(from) → \(to) language pack to translate.", bundle: .localized)
            case let .unsupportedPair(source, target):
                let from = source.displayName(in: locale)
                let to = target.displayName(in: locale)
                return String(localized: "\(from) can't be translated into \(to).", bundle: .localized)
            case .couldNotDetectLanguage:
                return String(localized: "Couldn't tell which language this book is in. Choose it in the translation panel.", bundle: .localized)
            case let .failed(reason):
                return String(localized: "Translation stopped: \(reason)", bundle: .localized)
            }
        }
    }

    /// Translations for the open book, keyed by `ComicPage.id`. Includes
    /// pages still in progress.
    private(set) var pages: [String: TranslatedPage] = [:]
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
    @ObservationIgnored private var pageSizes: [CGSize] = []
    /// The language this controller translates into (one controller per book
    /// and language — see `TranslationManager`).
    @ObservationIgnored private(set) var target: TranslationLanguage = .english
    /// Set by the first `reload`; until then `target` is only a default.
    @ObservationIgnored private(set) var isConfigured = false
    @ObservationIgnored private var scope: TranslationScope = .page
    @ObservationIgnored private var includeSoundEffects = false
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var plan: TranslationPlan?
    @ObservationIgnored private var finishedUnits: Set<Int> = []
    /// Units that failed; their pages aren't cached, so they retry next time.
    @ObservationIgnored private var failedUnits: Set<Int> = []
    @ObservationIgnored private var focusPage = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var jobTask: Task<Void, Never>?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var translatingSince: Date?
    @ObservationIgnored private var pagesCompletedThisJob = 0

    nonisolated static let maxConsecutiveFailures = 3
    nonisolated static let warmedUpBuildKey = "panely.translation.warmedUpBuild"

    init(
        store: TranslationStore,
        defaults: any KeyValueStoring = LiveKeyValueStore(),
        bookKey: String = "",
        title: String = "",
        bookURL: URL? = nil
    ) {
        self.store = store
        self.defaults = defaults
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
        pages = [:]
        completedPageIndices = []
        plan = nil
        finishedUnits = []
        failedUnits = []
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
        includeSoundEffects: Bool,
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
        self.includeSoundEffects = includeSoundEffects
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
        let wasWorking = isWorking || phase == .paused
        reload(
            pages: bookPages,
            pageSizes: pageSizes,
            scope: scope,
            source: language,
            target: target,
            includeSoundEffects: includeSoundEffects,
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

    /// Delete every cached translation (all books). The open book's overlays
    /// go too — they'd otherwise outlive their cache entries.
    func clearCache() async -> UInt64 {
        let snapshot = (bookPages, pageSizes, scope, source, target, includeSoundEffects, enabled, focusPage)
        clear()
        let store = store
        let removed = await Task.detached(priority: .utility) { store.clear() }.value
        reload(
            pages: snapshot.0, pageSizes: snapshot.1, scope: snapshot.2, source: snapshot.3, target: snapshot.4,
            includeSoundEffects: snapshot.5, enabled: snapshot.6, autoStart: false, focusPage: snapshot.7
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
        let includeSoundEffects = includeSoundEffects
        let focus = focusPage
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

            // 2. Language pack
            let status = await TranslationAvailability.status(from: source, to: target)
            guard status == .installed else {
                await self?.finishJob(
                    generation: generation,
                    notice: status == .needsDownload ? .needsLanguageDownload(source, target) : .unsupportedPair(source, target)
                )
                return
            }

            // 3. Plan
            let plan: TranslationPlan
            if scope == .strip {
                var sizes = knownSizes
                if sizes.count != bookPages.count {
                    sizes = []
                    for page in bookPages {
                        sizes.append((try? await ImageLoader.dimensions(for: page)) ?? .zero)
                    }
                }
                plan = .strip(StripLayout(pageSizes: sizes))
            } else {
                plan = .pages(count: bookPages.count)
            }
            guard await self?.adopt(plan, generation: generation) == true else { return }

            // 4. Work: OCR the next unit while translating the current one.
            let analyzer = PageAnalyzer(pages: bookPages, language: source, includeSoundEffects: includeSoundEffects)
            let translator = PageTranslator(from: source, to: target)
            var consecutiveFailures = 0
            var lastError: (any Error)?

            func analysis(of unit: TranslationUnit?) -> Task<[PageAnalysis], any Error>? {
                unit.map { unit in Task { try await analyzer.analyze(unit, plan: plan) } }
            }

            var current = await self?.claimNextUnit(excluding: [], generation: generation)
            var pending = analysis(of: current)
            while let unit = current, let analysisTask = pending {
                var next: TranslationUnit?
                var nextAnalysis: Task<[PageAnalysis], any Error>?
                var unitFailed = false
                do {
                    let analyses = try await analysisTask.value
                    let queue = await self?.merge(analyses, generation: generation) ?? []
                    // Prefetch: the next unit's OCR overlaps this unit's translation.
                    next = await self?.claimNextUnit(excluding: [unit.id], generation: generation)
                    nextAnalysis = analysis(of: next)
                    for item in queue {
                        try Task.checkCancellation()
                        let translation = try await translator.translate(item.source)
                        await self?.setTranslation(translation, pageIndex: item.pageIndex, bubbleID: item.bubbleID, generation: generation)
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        nextAnalysis?.cancel()
                        return
                    }
                    AppLog.error(.reader, "Translation unit failed", metadata: ["unit": "\(unit.id)", "error": "\(error)"])
                    lastError = error
                    unitFailed = true
                    if next == nil {
                        next = await self?.claimNextUnit(excluding: [unit.id], generation: generation)
                        nextAnalysis = analysis(of: next)
                    }
                }
                await self?.finishUnit(unit.id, failed: unitFailed, generation: generation)
                consecutiveFailures = unitFailed ? consecutiveFailures + 1 : 0
                if consecutiveFailures >= Self.maxConsecutiveFailures {
                    nextAnalysis?.cancel()
                    await self?.finishJob(generation: generation, notice: .failed(lastError?.localizedDescription ?? ""))
                    return
                }
                current = next
                pending = nextAnalysis
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
        let keyed = bookPages.enumerated().map {
            ($0.offset, $0.element.id, TranslationStore.key(pageID: $0.element.id, from: source, to: target, scope: scope))
        }
        let cached = await Task.detached(priority: .utility) {
            var found: [(Int, String, TranslatedPage)] = []
            for (index, id, key) in keyed {
                if let page = store.load(key: key), page.isComplete { found.append((index, id, page)) }
            }
            return found
        }.value
        guard self.generation == generation else { return }
        for (index, id, page) in cached where pages[id]?.isComplete != true {
            pages[id] = page
            completedPageIndices.insert(index)
        }
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
        pagesCompletedThisJob = 0
        return true
    }

    private func claimNextUnit(excluding inFlight: Set<Int>, generation: Int) -> TranslationUnit? {
        guard self.generation == generation, let plan else { return nil }
        return plan.nextUnit(excluding: finishedUnits.union(inFlight), focusPage: focusPage)
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
            pages[id] = page
        }
        return queue
    }

    private func setTranslation(_ text: String, pageIndex: Int, bubbleID: Int, generation: Int) {
        guard self.generation == generation, bookPages.indices.contains(pageIndex) else { return }
        let id = bookPages[pageIndex].id
        guard var page = pages[id], let index = page.bubbles.firstIndex(where: { $0.id == bubbleID }) else { return }
        page.bubbles[index].translation = text
        pages[id] = page
    }

    private func finishUnit(_ unitID: Int, failed: Bool, generation: Int) {
        guard self.generation == generation, let plan else { return }
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
                pages[id] = page
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
            page.isComplete = true
            pages[id] = page
            completedPageIndices.insert(index)
            pagesCompletedThisJob += 1
            if !failedPages.contains(index), let source, page.imageWidth > 0 {
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

    private func finishJob(generation: Int, notice: Notice?) {
        guard self.generation == generation else { return }
        jobTask = nil
        phase = .idle
        translatingSince = nil
        releaseAccess()
        self.notice = notice
        AppLog.info(.reader, "Translation finished", metadata: ["notice": "\(String(describing: notice))"])
        onJobEnded?()
    }
}
