import CoreGraphics
import Foundation

/// Experimental translation assist. The heavy lifting lives on
/// `TranslationController` (one book into one language) and
/// `TranslationManager` (all of them); this extension feeds them the open book
/// and the user's settings, and exposes what the viewer, toolbar, panel, menus
/// and Settings read.
///
/// What's chosen where:
/// - **Shown language** — per series: pick Korean, English… for a series and
///   it stays that way for its other volumes. New series start in the default
///   language (Settings; "System Default" follows the interface language).
/// - **On/off** — showing the original instead of a translation (⇧⌘T, or
///   "Original" in the panel), global.
/// - **The book's own language** — per series, detected the first time and
///   correctable in the panel.
/// - Sound effects — global.
///
/// A book can have several translations; each language is its own job with
/// its own progress and cache, and the balloon popover shows them side by side.
/// Jobs outlive the open book: opening another book leaves them running in the
/// background, and reopening the book reattaches to them.
///
/// Balloons can be corrected in edit mode (⇧⌘E) — a translation rewritten,
/// the recognised original fixed and translated again, a misread balloon
/// hidden. Reading stays clean: edit marks and hidden-balloon outlines only
/// show while editing. Edits (`TranslationEdits`) are kept apart from the
/// machine translations and laid over them for display.
///
/// It's a comprehension aid: originals stay one click (or ⇧⌘T) away, and
/// nothing is written back into the user's files.
extension ReaderViewModel {
    /// The open book in the language it's shown in.
    var translation: TranslationController { translationManager.current }

    /// Turned on in Settings *and* running on macOS 26+.
    var translationFeatureAvailable: Bool {
        preferences.translationEnabled && TranslationController.isSupportedOnThisMac
    }

    var translationEnabled: Bool {
        get { preferences.translationEnabled }
        set {
            guard preferences.translationEnabled != newValue else { return }
            preferences.translationEnabled = newValue
            reloadTranslations()
        }
    }

    // MARK: - Languages

    /// Default language for series without their own choice: the chosen one,
    /// or the interface language. Setting it makes it an explicit choice.
    var translationTargetLanguage: TranslationLanguage {
        get { translationTargetChoice ?? .defaultTarget(forInterfaceLanguage: localization.language) }
        set { translationTargetChoice = newValue }
    }

    /// The default as chosen in Settings; `nil` = "System Default".
    var translationTargetChoice: TranslationLanguage? {
        get { preferences.translationTargetLanguage }
        set {
            guard preferences.translationTargetLanguage != newValue else { return }
            preferences.translationTargetLanguage = newValue
            reloadTranslations()
        }
    }

    /// The language the open book is shown in: its series' choice, else the default.
    var translationDisplayLanguage: TranslationLanguage {
        get { seriesPreferences.translationTarget(forSeries: seriesIdentity) ?? translationTargetLanguage }
        set {
            seriesPreferences.setTranslationTarget(newValue, forSeries: seriesIdentity)
            guard hasSource else { return }
            translationManager.setDisplayTarget(newValue)
            let (controller, isNew) = translationManager.controller(for: newValue)
            if isNew { setUp(controller, target: newValue, autoStart: false, restart: false) }
        }
    }

    /// The open book's own language: remembered for its series (or just
    /// detected). `nil` until the first translation detects it. Setting it
    /// remembers the choice for the series and reloads every language's results.
    var translationSourceLanguage: TranslationLanguage? {
        get { translation.source ?? seriesPreferences.translationSource(forSeries: seriesIdentity) }
        set {
            guard let newValue else { return }
            seriesPreferences.setTranslationSource(newValue, forSeries: seriesIdentity)
            for controller in translationManager.openBook {
                controller.setSource(newValue)
            }
        }
    }

    /// The open book's translations to list in the panel: the shown language
    /// plus every language with results or a job, shown one first.
    var translationLanguagesForBook: [TranslationController] {
        let source = translationSourceLanguage
        let display = translationDisplayLanguage
        return translationManager.openBook
            .filter { $0.target != source && ($0.target == display || $0.completedPageCount > 0 || $0.hasActiveJob) }
            .sorted { a, b in
                if (a.target == display) != (b.target == display) { return a.target == display }
                return a.target.rawValue < b.target.rawValue
            }
    }

    var translationIncludeSoundEffects: Bool {
        get { preferences.translationIncludeSoundEffects }
        set {
            guard preferences.translationIncludeSoundEffects != newValue else { return }
            preferences.translationIncludeSoundEffects = newValue
            reloadTranslations()
        }
    }

    /// Fast or accurate model (Settings). Running jobs restart in the new mode.
    var translationMode: TranslationMode {
        get { preferences.translationMode }
        set {
            guard preferences.translationMode != newValue else { return }
            preferences.translationMode = newValue
            reloadTranslations()
        }
    }

    /// Start translating whenever a book of this series opens.
    var translationAutoTranslatesSeries: Bool {
        get { seriesPreferences.autoTranslate(forSeries: seriesIdentity) }
        set { seriesPreferences.setAutoTranslate(newValue, forSeries: seriesIdentity) }
    }

    // MARK: - Showing

    /// Whether a translation is painted over the page (off = the original).
    /// A setting: it stays on for a book with nothing translated yet.
    var translationOverlayVisible: Bool {
        preferences.translationOverlayVisible
    }

    /// What's actually on screen: translation on *and* this book has some of
    /// the shown language (or is getting it). The toolbar and panel mark the
    /// language as selected only then — the series remembers its language,
    /// so a new volume would otherwise show one ticked with nothing of it.
    var translationIsShowing: Bool {
        translationOverlayVisible && (!translation.pages.isEmpty || translation.hasActiveJob)
    }

    /// The open book's languages with something to show — what can be
    /// switched to. The rest can only be started.
    var translationLanguagesWithResults: [TranslationController] {
        translationLanguagesForBook.filter { !$0.pages.isEmpty || $0.hasActiveJob }
    }

    func toggleTranslationOverlay() {
        guard translationFeatureAvailable else { return }
        preferences.translationOverlayVisible.toggle()
        if !preferences.translationOverlayVisible { isEditingTranslations = false }
    }

    /// Show the original pages (translation off).
    func showOriginal() {
        preferences.translationOverlayVisible = false
        isEditingTranslations = false
    }

    // MARK: - Edit mode

    /// Edit mode needs a translation on screen to edit.
    var canEditTranslations: Bool {
        translationFeatureAvailable && hasSource && !translation.pages.isEmpty
    }

    /// Enter or leave balloon edit mode. Entering shows the translation.
    func setEditingTranslations(_ editing: Bool) {
        guard !editing || canEditTranslations else { return }
        if editing { preferences.translationOverlayVisible = true }
        isEditingTranslations = editing
        if !editing { translationEdits.dismissRecentlyHidden() }
    }

    func toggleEditingTranslations() {
        setEditingTranslations(!isEditingTranslations)
    }

    /// Whether the translation panel's "click a balloon" tip still shows.
    var showsTranslationBalloonTip: Bool {
        get { !preferences.translationBalloonTipDismissed }
        set { preferences.translationBalloonTipDismissed = !newValue }
    }

    /// Show the book in `language` (translation on).
    func showTranslation(in language: TranslationLanguage) {
        guard translationFeatureAvailable else { return }
        if language != translationDisplayLanguage {
            translationDisplayLanguage = language
        }
        preferences.translationOverlayVisible = true
    }

    /// Paged books are read page by page; the vertical layout reads the
    /// pages as one strip so balloons split across slices come back whole.
    var translationScope: TranslationScope {
        layout.isContinuous ? .strip : .page
    }

    /// Translations for the images on screen, aligned with `currentImages`
    /// (empty when the feature is off), with the reader's edits applied. Each
    /// balloon also carries the book's other languages for the popover.
    var translationOverlayPages: [TranslatedPage?] {
        guard translationFeatureAvailable else { return [] }
        let shown = translation
        let others = translationManager.openBook.filter { $0 !== shown && !$0.pages.isEmpty }
        return imageLoader.currentPageIDs.map { id in
            guard let machine = shown.pages[id] else { return nil }
            var page = translationEdits.apply(to: machine, pageID: id, target: shown.target, includeHidden: isEditingTranslations)
            page.pageID = id
            guard !others.isEmpty else { return page }
            let edits = translationEdits.edits(forPage: id)
            for index in page.bubbles.indices {
                var alternates: [TranslationLanguage: String] = [:]
                for other in others {
                    guard let bubble = other.pages[id]?.bubbles.first(where: { $0.source == page.bubbles[index].source }) else { continue }
                    if let text = edits?.translation(of: bubble, in: other.target) ?? bubble.translation, !text.isEmpty {
                        alternates[other.target] = text
                    }
                }
                page.bubbles[index].alternates = alternates.isEmpty ? nil : alternates
            }
            return page
        }
    }

    /// Indices of pages translated into the shown language (thumbnails, slider).
    var translatedPageIndices: Set<Int> {
        translationFeatureAvailable ? translation.completedPageIndices : []
    }

    // MARK: - Jobs

    /// Start the shown language's job from the page on screen, or pause it.
    func toggleTranslatingCurrentBook() {
        guard translationFeatureAvailable, hasSource else { return }
        if translation.isWorking || translation.phase == .queued {
            translationManager.pause(translation)
        } else {
            startTranslatingCurrentBook()
        }
    }

    /// Translate the open book into the shown language.
    func startTranslatingCurrentBook() {
        startTranslating(into: translationDisplayLanguage)
    }

    /// Translate the open book into `language` (shown or not).
    func startTranslating(into language: TranslationLanguage) {
        guard translationFeatureAvailable, hasSource else { return }
        let (controller, isNew) = translationManager.controller(for: language)
        if isNew { setUp(controller, target: language, autoStart: false, restart: false) }
        if language == translationDisplayLanguage {
            // Starting the shown language implies wanting to see it.
            preferences.translationOverlayVisible = true
        }
        controller.setFocus(currentPageIndex)
        translationManager.start(controller)
    }

    func pauseTranslating() {
        translationManager.pause(translation)
    }

    func stopTranslating() {
        translationManager.stop(translation)
    }

    func dismissTranslationNotice() {
        translation.notice = nil
    }

    // MARK: - Edits

    /// A change the reader made in a balloon's popover. Translations written
    /// by the reader belong to the shown language; hiding and corrected
    /// originals hold for every language.
    func applyTranslationEdit(_ request: TranslationEditRequest) {
        let target = translation.target
        let bubble = request.bubble
        switch request.change {
        case let .setTranslation(text):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            translationEdits.update(pageID: request.pageID, bubble: bubble) { edit in
                edit.translations[target.rawValue] = text.isEmpty ? nil : text
            }
        case .revertTranslation:
            translationEdits.update(pageID: request.pageID, bubble: bubble) { edit in
                edit.translations[target.rawValue] = nil
            }
        case .hide:
            translationEdits.hide(pageID: request.pageID, bubble: bubble)
        case let .correctSource(text):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let corrected = text.isEmpty || text == bubble.source ? nil : text
            translationEdits.update(pageID: request.pageID, bubble: bubble) { edit in
                edit.correctedSource = corrected
                edit.retranslations = [:]
            }
            guard let corrected else { return }
            // Every language the balloon is translated into gets the
            // correction, the shown one first.
            let targets = [target] + translationManager.openBook
                .filter { $0.target != target && $0.pages[request.pageID]?.bubbles.contains { $0.source == bubble.source } == true }
                .map(\.target)
            for language in targets {
                retranslate(bubble, correctedSource: corrected, pageID: request.pageID, into: language)
            }
        case .revertSource:
            translationEdits.update(pageID: request.pageID, bubble: bubble) { edit in
                edit.correctedSource = nil
                edit.retranslations = [:]
            }
        case .revertAll:
            translationEdits.update(pageID: request.pageID, bubble: bubble) { edit in
                edit.translations[target.rawValue] = nil
                edit.correctedSource = nil
                edit.retranslations = [:]
            }
        case .retranslate:
            guard let corrected = bubble.edit?.correctedSource else { return }
            retranslate(bubble, correctedSource: corrected, pageID: request.pageID, into: target)
        case .show:
            translationEdits.update(pageID: request.pageID, bubble: bubble) { edit in
                edit.isHidden = false
            }
        case .enterEditMode:
            setEditingTranslations(true)
        }
    }

    /// The open book's hidden balloons in reading order, for the panel's list.
    var translationHiddenBalloons: [HiddenBalloon] {
        let pageIndices = Dictionary(source.pages.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return translationEdits.hiddenBalloons
            .compactMap { item in
                pageIndices[item.pageID].map { HiddenBalloon(pageIndex: $0, pageID: item.pageID, edit: item.edit) }
            }
            .sorted { ($0.pageIndex, $0.edit.rect.minY) < ($1.pageIndex, $1.edit.rect.minY) }
    }

    /// Translate a corrected original on its own, outside the book's job.
    /// Needs the language pack like the job does; without it the balloon
    /// keeps offering to try again and the banner offers the download.
    private func retranslate(_ bubble: TranslatedBubble, correctedSource: String, pageID: String, into target: TranslationLanguage) {
        guard #available(macOS 26.0, *), let source = translationSourceLanguage, source != target else { return }
        let retranslation = TranslationEdits.Retranslation(
            pageID: pageID,
            recognizedSource: bubble.source,
            correctedSource: correctedSource,
            target: target
        )
        translationEdits.beginRetranslation(retranslation)
        let mode = translationMode
        Task { [weak self] in
            let text: String? = await Task.detached(priority: .userInitiated) {
                do {
                    return try await PageTranslator(from: source, to: target, mode: mode).translate(correctedSource)
                } catch {
                    AppLog.error(.reader, "Translating a corrected balloon failed", metadata: ["error": "\(error)"])
                    return nil
                }
            }.value
            guard let self else { return }
            self.translationEdits.finishRetranslation(retranslation, bubble: bubble, text: text)
            if text == nil, target == self.translation.target,
               await TranslationAvailability.status(from: source, to: target, mode: mode) == .needsDownload {
                self.translation.notice = .needsLanguageDownload(source, target)
            }
        }
    }

    // MARK: - Series

    /// Other volumes of the open book's series that the series translation
    /// would add: neighbours whose title matches once volume numbering is
    /// stripped (see `SeriesVolumeMatcher`) — not simply everything else in
    /// the folder, which may be unrelated works.
    var translatableSeriesVolumes: [URL] {
        guard let current = currentSourceURL else { return [] }
        return SeriesVolumeMatcher.volumes(matching: current, among: siblings)
    }

    /// Translate the open book, then every other volume of the series in the
    /// background, one after another, into the shown language. Volumes whose
    /// pages can't be read outside the reader (archives inside archives) are
    /// skipped and listed.
    func translateEntireSeries() async {
        guard translationFeatureAvailable, hasSource else { return }
        seriesTranslationSkipped = []
        startTranslatingCurrentBook()
        let seriesID = seriesIdentity
        let scope = translationScope
        let target = translationDisplayLanguage
        let libraryURL = libraryScope.url
        for url in translatableSeriesVolumes {
            let (controller, isNew) = translationManager.backgroundController(
                bookKey: url.standardizedFileURL.path,
                title: url.deletingPathExtension().lastPathComponent,
                bookURL: url,
                target: target
            )
            guard isNew else {
                if !controller.hasActiveJob { translationManager.start(controller) }
                continue
            }
            guard let volume = await loadVolumeForTranslation(url) else {
                translationManager.stop(controller)
                seriesTranslationSkipped.append(url.deletingPathExtension().lastPathComponent)
                continue
            }
            configure(controller, seriesID: seriesID, accessURLs: [libraryURL, url].compactMap { $0 })
            controller.reload(
                pages: volume.pages,
                pageSizes: [],
                scope: scope,
                source: seriesPreferences.translationSource(forSeries: seriesID),
                target: target,
                includeSoundEffects: translationIncludeSoundEffects,
                mode: translationMode,
                enabled: true,
                autoStart: true,
                focusPage: 0
            )
        }
    }

    /// The open book is an archive inside an archive, unpacked to a temporary
    /// folder that's deleted once the reader moves on — so its translation
    /// can't continue in the background.
    var currentBookLivesInTemporaryFolder: Bool {
        guard let tempRoot = tempDir.url, let url = currentSourceURL else { return false }
        return tempRoot.relativeSubpath(to: url) != nil
    }

    /// Bring a book with a translation job to the front.
    func openTranslationJobBook(_ controller: TranslationController) {
        guard let url = controller.bookURL else { return }
        openLibraryURL(url)
    }

    // MARK: - Setup

    /// Called whenever `source` changes (see its `didSet`). The old book's
    /// overlays go immediately (its jobs, if any, carry on in the background);
    /// the new book is set up once the load has also restored the series'
    /// layout — which decides page vs strip — later in the same main-actor turn.
    func translationSourceDidChange() {
        seriesTranslationSkipped = []
        isEditingTranslations = false
        translationManager.detachOpenBook()
        Task { @MainActor [weak self] in
            self?.reloadTranslations(autoStart: true, bookChanged: true)
        }
    }

    /// Set up the open book's translations for the current settings: the
    /// shown language, plus every other language so results cached for them
    /// show up in the panel. On a book change, jobs still running for the book
    /// are reattached as they are; on a settings change running jobs restart
    /// with the new settings. `autoStart` honours the series' auto-translate.
    func reloadTranslations(autoStart: Bool = false, bookChanged: Bool = false) {
        let editedPageIDs = translationFeatureAvailable && hasSource ? source.pages.map(\.id) : []
        let editScope = translationScope
        Task { await translationEdits.load(pageIDs: editedPageIDs, scope: editScope) }
        if bookChanged {
            guard let url = currentSourceURL, hasSource else { return }
            translationManager.beginBook(
                key: url.standardizedFileURL.path,
                title: source.title.isEmpty ? url.deletingPathExtension().lastPathComponent : source.title,
                url: url
            )
        }
        let display = translationDisplayLanguage
        translationManager.setDisplayTarget(display)
        let source = seriesPreferences.translationSource(forSeries: seriesIdentity)
        let targets = [display] + TranslationLanguage.allCases.filter { $0 != display && $0 != source }
        for target in targets {
            let (controller, isNew) = translationManager.controller(for: target)
            if bookChanged && !isNew {
                controller.setFocus(currentPageIndex) // reattached job
                continue
            }
            setUp(
                controller,
                target: target,
                autoStart: autoStart && target == display && translationAutoTranslatesSeries,
                restart: !isNew
            )
        }
    }

    /// Point `controller` at the open book in `target`. `restart` keeps a job
    /// that was running (a settings change shouldn't silently drop it).
    private func setUp(_ controller: TranslationController, target: TranslationLanguage, autoStart: Bool, restart: Bool) {
        let wasActive = restart && (controller.isWorking || controller.phase == .queued)
        controller.requiresOpenBook = currentBookLivesInTemporaryFolder
        configure(
            controller,
            seriesID: seriesIdentity,
            accessURLs: [libraryScope.url, openedSourceURL, currentSourceURL].compactMap { $0 }
        )
        let enabled = translationFeatureAvailable && hasSource
        controller.reload(
            pages: source.pages,
            pageSizes: layout.isContinuous ? pageDimensions : [],
            scope: translationScope,
            source: seriesPreferences.translationSource(forSeries: seriesIdentity),
            target: target,
            includeSoundEffects: translationIncludeSoundEffects,
            mode: translationMode,
            enabled: enabled,
            autoStart: enabled && (wasActive || autoStart),
            focusPage: currentPageIndex
        )
    }

    private func loadVolumeForTranslation(_ url: URL) async -> ComicSource? {
        if isDirectory(url) {
            return try? await Task.detached(priority: .utility) { try FolderLoader.load(from: url) }.value
        }
        guard (try? await ArchiveLoader.hasNestedArchives(at: url)) == false else { return nil }
        return try? await ArchiveLoader.load(from: url)
    }

    /// Series-level wiring shared by the open book and queued volumes: a
    /// detected language is remembered for the series and handed to the
    /// book's other languages, and a volume queued before detection picks it
    /// up when its turn comes.
    private func configure(_ controller: TranslationController, seriesID: String, accessURLs: [URL]) {
        controller.accessURLs = accessURLs
        controller.onSourceDetected = { [weak self] language in
            guard let self else { return }
            self.seriesPreferences.setTranslationSource(language, forSeries: seriesID)
            for other in self.translationManager.openBook where other.source == nil {
                other.setSource(language)
            }
        }
        controller.sourceResolver = { [weak self] in
            self?.seriesPreferences.translationSource(forSeries: seriesID)
        }
    }
}
