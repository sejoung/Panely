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
    /// Cached pages getting their speech levels matched (`SpeechLevel`) —
    /// pages done and to do — while that runs.
    private(set) var speechLevelProgress: SpeechLevelProgress?
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
    @ObservationIgnored private(set) var scope: TranslationScope = .page
    /// Already `effective` for this Mac.
    @ObservationIgnored private(set) var mode: TranslationMode = .accurate
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var plan: TranslationPlan?
    @ObservationIgnored private var finishedUnits: Set<Int> = []
    /// Units that failed; their pages aren't cached, so they retry next time.
    @ObservationIgnored private var failedUnits: Set<Int> = []
    @ObservationIgnored private var focusPage = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var jobTask: Task<Void, Never>?
    /// Readable so tests can await the cache load instead of sleeping.
    @ObservationIgnored private(set) var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var translatingSince: Date?
    @ObservationIgnored private var pagesCompletedThisJob = 0
    /// Match each translation's speech level to the original's (Settings).
    @ObservationIgnored private var matchSpeechLevel = false
    /// Set by a job that matches speech levels, so its pages are saved as checked.
    @ObservationIgnored private var jobMatchesSpeechLevel = false
    /// Where each cached page was found, so matching its speech level later
    /// saves it back to the same entry.
    @ObservationIgnored private var cacheKeys: [String: String] = [:]
    @ObservationIgnored private var speechLevelTask: Task<Void, Never>?
    /// Makes the corrector for a pair (`nil` when it doesn't apply). Tests
    /// swap in a stand-in for the on-device model.
    @ObservationIgnored var makeSpeechLevelCorrector: (TranslationLanguage, TranslationLanguage) -> (any SpeechLevelCorrecting)? = SpeechLevelCorrectors.make

    nonisolated static let maxConsecutiveFailures = 3
    /// Pages read ahead in fast mode. Three keep translation fed on an M1
    /// Pro without OCR running far ahead of a reader who jumps around.
    nonisolated static let fastLookahead = 3
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
        speechLevelTask?.cancel()
        speechLevelTask = nil
        speechLevelProgress = nil
        cacheKeys = [:]
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
        mode: TranslationMode = .accurate,
        matchSpeechLevel: Bool = false,
        enabled: Bool,
        autoStart: Bool,
        focusPage: Int
    ) {
        clear()
        isConfigured = true
        self.matchSpeechLevel = matchSpeechLevel
        self.bookPages = enabled ? bookPages : []
        self.pageSizes = pageSizes.count == bookPages.count ? pageSizes : []
        self.scope = scope
        self.source = source
        self.target = target
        self.mode = mode.effective
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
            self.matchCachedSpeechLevels()
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
            mode: mode,
            matchSpeechLevel: matchSpeechLevel,
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
    /// detector, speech levels matched) get it without clearing the whole
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
        speechLevelTask?.cancel()
        speechLevelTask = nil
        speechLevelProgress = nil
        notice = nil

        var keys: [String] = []
        for index in indices {
            let id = bookPages[index].id
            pages[id] = nil
            cacheKeys[id] = nil
            completedPageIndices.remove(index)
            // Either mode's entry: a fast job reads accurate ones too.
            keys += [TranslationMode.accurate, .fast].map {
                TranslationStore.key(pageID: id, from: source, to: target, scope: scope, mode: $0)
            }
        }
        plan = nil
        finishedUnits = []
        failedUnits = []
        focusPage = indices.min() ?? focusPage
        let store = store
        await Task.detached(priority: .utility) { store.remove(keys: keys) }.value
        AppLog.info(.reader, "Translating pages again", metadata: ["pages": "\(indices.count)"])
        if let requestStart { requestStart() } else { start() }
    }

    /// Delete every cached translation (all books). The open book's overlays
    /// go too — they'd otherwise outlive their cache entries.
    func clearCache() async -> UInt64 {
        let snapshot = (bookPages, pageSizes, scope, source, target, enabled, focusPage, mode, matchSpeechLevel)
        clear()
        let store = store
        let removed = await Task.detached(priority: .utility) { store.clear() }.value
        reload(
            pages: snapshot.0, pageSizes: snapshot.1, scope: snapshot.2, source: snapshot.3, target: snapshot.4,
            mode: snapshot.7, matchSpeechLevel: snapshot.8, enabled: snapshot.5,
            autoStart: false, focusPage: snapshot.6
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
        let mode = mode
        let focus = focusPage
        phase = knownSource == nil ? .detectingLanguage : .preparing
        AppLog.info(.reader, "Translation started", metadata: [
            "pages": "\(bookPages.count)", "scope": "\(scope.rawValue)", "target": "\(target.rawValue)", "mode": "\(mode.rawValue)",
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
            let status = await TranslationAvailability.status(from: source, to: target, mode: mode)
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
            let analyzer = PageAnalyzer(pages: bookPages, language: source)
            let translator = PageTranslator(from: source, to: target, mode: mode)
            let speechLevel = await self?.beginMatchingSpeechLevel(source: source, generation: generation)
            var consecutiveFailures = 0
            var lastError: (any Error)?
            // Each balloon costs the translator ~0.5 s whatever else runs, so
            // text seen earlier in the book ("하치켄!", a recurring sign) is
            // reused instead of translated again.
            var translatedTexts: [String: String] = [:]
            var stats = TranslationJobStats()
            defer { AppLog.info(.reader, "Translation job stats", metadata: stats.metadata) }

            // OCR runs ahead of translation. Accurate translation (~6 s a
            // page) hides one page of OCR; fast translation (~0.3 s a page)
            // would wait on it, so several pages are read at once — Vision
            // runs them in parallel.
            let lookaheadDepth = mode == .fast ? Self.fastLookahead : 1
            var lookahead: [(unit: TranslationUnit, analysis: Task<[PageAnalysis], any Error>)] = []
            func fillLookahead(excluding current: Int?) async {
                while lookahead.count < lookaheadDepth {
                    let inFlight = Set(lookahead.map(\.unit.id) + [current].compactMap { $0 })
                    guard let unit = await self?.claimNextUnit(excluding: inFlight, generation: generation) else { return }
                    lookahead.append((unit, Task { try await analyzer.analyze(unit, plan: plan) }))
                }
            }
            func cancelLookahead() {
                for entry in lookahead { entry.analysis.cancel() }
            }

            await fillLookahead(excluding: nil)
            while !lookahead.isEmpty {
                let (unit, analysisTask) = lookahead.removeFirst()
                var unitFailed = false
                do {
                    let waitStart = ContinuousClock.now
                    let analyses = try await analysisTask.value
                    stats.analysisWait += waitStart.duration(to: .now)
                    let queue = await self?.merge(analyses, generation: generation) ?? []
                    // Prefetch: the next units' OCR overlaps this unit's translation.
                    await fillLookahead(excluding: unit.id)
                    for item in queue {
                        try Task.checkCancellation()
                        let translation: String
                        if let known = translatedTexts[item.source] {
                            translation = known
                            stats.reused += 1
                        } else {
                            let start = ContinuousClock.now
                            var text = try await translator.translate(item.source)
                            stats.translating += start.duration(to: .now)
                            stats.translated += 1
                            if let speechLevel {
                                let start = ContinuousClock.now
                                if let matched = await speechLevel.correct(text, source: item.source) {
                                    text = matched
                                    stats.speechLevelMatched += 1
                                }
                                stats.matchingSpeechLevel += start.duration(to: .now)
                            }
                            translation = text
                            translatedTexts[item.source] = translation
                        }
                        let start = ContinuousClock.now
                        await self?.setTranslation(translation, pageIndex: item.pageIndex, bubbleID: item.bubbleID, generation: generation)
                        stats.publishing += start.duration(to: .now)
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        cancelLookahead()
                        return
                    }
                    AppLog.error(.reader, "Translation unit failed", metadata: ["unit": "\(unit.id)", "error": "\(error)"])
                    lastError = error
                    unitFailed = true
                    await fillLookahead(excluding: unit.id)
                }
                await self?.finishUnit(unit.id, failed: unitFailed, generation: generation)
                stats.units += 1
                consecutiveFailures = unitFailed ? consecutiveFailures + 1 : 0
                if consecutiveFailures >= Self.maxConsecutiveFailures {
                    cancelLookahead()
                    await self?.finishJob(generation: generation, notice: .failed(lastError?.localizedDescription ?? ""))
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
        // A fast job takes accurate translations already made over its own;
        // an accurate job only reads its own.
        let modes: [TranslationMode] = mode == .fast ? [.accurate, .fast] : [.accurate]
        let keyed = bookPages.enumerated().map { page in
            (page.offset, page.element.id, modes.map {
                TranslationStore.key(pageID: page.element.id, from: source, to: target, scope: scope, mode: $0)
            })
        }
        let cached = await Task.detached(priority: .utility) {
            var found: [(Int, String, TranslatedPage, String)] = []
            for (index, id, keys) in keyed {
                for key in keys {
                    if let page = store.load(key: key), page.isComplete {
                        found.append((index, id, page, key))
                        break
                    }
                }
            }
            return found
        }.value
        guard self.generation == generation else { return }
        for (index, id, page, key) in cached where pages[id]?.isComplete != true {
            pages[id] = page
            cacheKeys[id] = key
            completedPageIndices.insert(index)
        }
    }

    // MARK: - Speech level

    /// The corrector for this book's pair, when matching is on and applies.
    private func speechLevelCorrector(source: TranslationLanguage?) -> (any SpeechLevelCorrecting)? {
        guard matchSpeechLevel, enabled, let source else { return nil }
        return makeSpeechLevelCorrector(source, target)
    }

    /// A job's corrector, noted so its pages are saved as matched.
    private func beginMatchingSpeechLevel(source: TranslationLanguage, generation: Int) -> (any SpeechLevelCorrecting)? {
        guard self.generation == generation else { return nil }
        let corrector = speechLevelCorrector(source: source)
        jobMatchesSpeechLevel = corrector != nil
        return corrector
    }

    /// Match the speech levels of finished pages that haven't been — cached
    /// before matching existed, or while it was off — from the page being
    /// read outward. Each page is saved back once matched, so it's done once.
    func matchCachedSpeechLevels() {
        guard speechLevelTask == nil, let corrector = speechLevelCorrector(source: source) else { return }
        let todo = Self.translationOrder(count: bookPages.count, startingAt: focusPage).compactMap { index -> (String, TranslatedPage)? in
            let id = bookPages[index].id
            guard let page = pages[id], page.isComplete, page.speechLevelChecked != true else { return nil }
            return (id, page)
        }
        guard !todo.isEmpty else { return }
        let generation = generation
        speechLevelProgress = SpeechLevelProgress(done: 0, total: todo.count)
        speechLevelTask = Task.detached(priority: .utility) { [weak self] in
            var matched = 0
            for (done, (id, page)) in todo.enumerated() {
                guard !Task.isCancelled else { return }
                var page = page
                for index in page.bubbles.indices {
                    guard let text = page.bubbles[index].translation, !text.isEmpty else { continue }
                    if let corrected = await corrector.correct(text, source: page.bubbles[index].source) {
                        page.bubbles[index].translation = corrected
                        matched += 1
                    }
                }
                page.speechLevelChecked = true
                guard await self?.speechLevelMatched(page, id: id, done: done + 1, generation: generation) == true else { return }
            }
            await self?.endMatchingSpeechLevel(generation: generation, matched: matched)
        }
    }

    private func speechLevelMatched(_ page: TranslatedPage, id: String, done: Int, generation: Int) -> Bool {
        guard self.generation == generation else { return false }
        // Left alone if it changed meanwhile (cleared, or retranslated).
        if pages[id]?.isComplete == true, pages[id]?.speechLevelChecked != true {
            pages[id] = page
            if let source {
                let key = cacheKeys[id] ?? TranslationStore.key(pageID: id, from: source, to: target, scope: scope, mode: mode)
                let store = store
                Task.detached(priority: .utility) { try? store.save(page, key: key) }
            }
        }
        speechLevelProgress?.done = done
        return true
    }

    private func endMatchingSpeechLevel(generation: Int, matched: Int) {
        guard self.generation == generation else { return }
        AppLog.info(.reader, "Speech levels matched", metadata: [
            "pages": "\(speechLevelProgress?.total ?? 0)", "balloons": "\(matched)",
        ])
        speechLevelTask = nil
        speechLevelProgress = nil
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
            if jobMatchesSpeechLevel { page.speechLevelChecked = true }
            pages[id] = page
            completedPageIndices.insert(index)
            pagesCompletedThisJob += 1
            if !failedPages.contains(index), let source, page.imageWidth > 0 {
                toSave.append((TranslationStore.key(pageID: id, from: source, to: target, scope: scope, mode: mode), page))
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
        jobMatchesSpeechLevel = false
        AppLog.info(.reader, "Translation finished", metadata: ["notice": "\(String(describing: notice))"])
        onJobEnded?()
        // Pages a cache load brought in meanwhile (a language detected
        // mid-job) still need matching.
        matchCachedSpeechLevels()
    }
}

/// Where a job's time went, logged when it ends — translating should be
/// nearly all of it; the rest is waiting for OCR or for the main actor.
private nonisolated struct TranslationJobStats {
    let started = ContinuousClock.now
    var units = 0
    var translated = 0
    var reused = 0
    var translating: Duration = .zero
    var speechLevelMatched = 0
    var matchingSpeechLevel: Duration = .zero
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
            "translatingSeconds": "\(format(seconds(translating)))",
            "speechLevelMatched": "\(speechLevelMatched)",
            "speechLevelSeconds": "\(format(seconds(matchingSpeechLevel)))",
            "analysisWaitSeconds": "\(format(seconds(analysisWait)))",
            "publishingSeconds": "\(format(seconds(publishing)))",
            "secondsPerBalloon": "\(format(translated > 0 ? seconds(translating) / Double(translated) : 0, 2))",
        ]
    }
}

/// Progress of matching cached pages' speech levels.
nonisolated struct SpeechLevelProgress: Equatable, Sendable {
    var done: Int
    let total: Int
}
