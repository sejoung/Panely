import Foundation

/// Exporting translated books: a copy of each book with its translations
/// painted into the pages (the reader's edits included), saved as a CBZ or a
/// folder of images. The last step of translating — read it anywhere, keep it.
///
/// An export is a background job like translating is: start it (a book, or a
/// whole series), keep reading something else, and follow it in the jobs
/// window. A book that isn't fully translated is translated first through the
/// usual queue, unless the reader chose to export it as it is.
///
/// Started from the toolbar's language menu, File › Export Translated Book…,
/// the translation panel (whole series) and the library's context menus.
extension ReaderViewModel {
    /// Exporting needs the translation feature; the book needn't be open.
    var canExportTranslations: Bool {
        translationFeatureAvailable
    }

    /// The open book can be exported.
    var canExportCurrentBook: Bool {
        canExportTranslations && hasSource && currentSourceURL != nil
    }

    /// The open book's series in reading order (the open book included), when
    /// it has other volumes.
    var currentSeriesVolumesForExport: [URL] {
        guard let current = currentSourceURL else { return [] }
        let others = Set(translatableSeriesVolumes.map(\.standardizedFileURL))
        guard !others.isEmpty else { return [] }
        let currentPath = current.standardizedFileURL
        return siblings.filter { others.contains($0.standardizedFileURL) || $0.standardizedFileURL == currentPath }
    }

    // MARK: - Asking

    func requestExportOfCurrentBook() {
        guard canExportCurrentBook, let url = currentSourceURL else { return }
        requestTranslationExport(books: [url], title: exportTitle(for: url), isSeries: false)
    }

    func requestExportOfCurrentSeries() {
        let volumes = currentSeriesVolumesForExport
        guard canExportTranslations, let first = volumes.first else { return }
        requestTranslationExport(books: volumes, title: first.deletingLastPathComponent().lastPathComponent, isSeries: true)
    }

    /// Bring up the export sheet for `books` (one book, or a series' volumes
    /// in order).
    func requestTranslationExport(books: [URL], title: String, isSeries: Bool) {
        guard canExportTranslations, let first = books.first else { return }
        // Volumes unpacked from an archive sit in a temporary folder; the
        // series is the archive they came from.
        var title = title
        if isSeries, let tempRoot = tempDir.url, tempRoot.relativeSubpath(to: first) != nil, let opened = openedSourceURL {
            title = opened.deletingPathExtension().lastPathComponent
        }
        let seriesID = ReaderSeriesIdentity.make(for: first, opened: openedSourceURL, tempRoot: tempDir.url) ?? ""
        translationExportRequest = TranslationExportRequest(
            books: books,
            title: title,
            isSeries: isSeries,
            suggestedTarget: seriesPreferences.translationTarget(forSeries: seriesID) ?? translationTargetLanguage
        )
    }

    /// The language `request`'s books are written in, when known — not
    /// offered as a target.
    func exportSourceLanguage(for request: TranslationExportRequest) -> TranslationLanguage? {
        guard let first = request.books.first else { return nil }
        let seriesID = ReaderSeriesIdentity.make(for: first, opened: openedSourceURL, tempRoot: tempDir.url) ?? ""
        return seriesPreferences.translationSource(forSeries: seriesID)
    }

    /// Some of `request`'s books only exist while their archive is open
    /// (archives inside archives, unpacked to a temporary folder).
    func exportNeedsOpenArchive(_ request: TranslationExportRequest) -> Bool {
        guard let tempRoot = tempDir.url else { return false }
        return request.books.contains { tempRoot.relativeSubpath(to: $0) != nil }
    }

    /// Pick the folder exports are saved to.
    func chooseTranslationExportDestination() {
        let request = FilePickerRequest(
            canChooseFiles: false,
            canChooseDirectories: true,
            prompt: String(localized: "Choose", bundle: .localized),
            message: String(localized: "Choose where translated books are saved.", bundle: .localized),
            directoryURL: translationExports.destination
        )
        guard let url = filePicker.pickURL(request) else { return }
        translationExports.setDestination(url)
    }

    // MARK: - Running

    /// Start exporting `request`'s books with `options`, one job per book.
    func startTranslationExport(_ request: TranslationExportRequest, options: TranslationExportOptions) {
        translationExports.options = options
        for url in request.books {
            let job = TranslationExportJob(bookURL: url, title: exportTitle(for: url), options: options)
            translationExports.add(job)
            job.task = Task { [weak self] in
                await self?.runTranslationExport(job)
            }
        }
    }

    /// Run a stopped job again, as a new job with the same choices.
    func retryTranslationExport(_ job: TranslationExportJob) {
        translationExports.dismiss(job)
        let retry = TranslationExportJob(bookURL: job.bookURL, title: job.title, options: job.options)
        translationExports.add(retry)
        retry.task = Task { [weak self] in
            await self?.runTranslationExport(retry)
        }
    }

    /// Open an exported book in the reader.
    func openExportedBook(_ record: TranslationExportRecord) {
        // Inside the export folder, which the app was granted; keep the
        // grant for as long as the book is read.
        _ = translationExports.destination?.startAccessingSecurityScopedResource()
        openURL(record.url)
    }

    private func runTranslationExport(_ job: TranslationExportJob) async {
        do {
            guard let folder = translationExports.destination else { throw TranslationExportError.noDestination }
            let prepared = try await prepareTranslationExport(job)
            try Task.checkCancellation()
            job.setStage(.waiting)
            await translationExports.beginRendering()
            let result: TranslationExportWriter.Result
            do {
                defer { translationExports.endRendering() }
                try Task.checkCancellation()
                result = try await writeTranslationExport(job, prepared: prepared, into: folder)
            }
            translationExports.finish(job, result: result, pageCount: prepared.writer.pages.count)
            AppLog.info(.reader, "Translation export finished", metadata: [
                "pages": "\(prepared.writer.pages.count)", "format": "\(job.options.format.rawValue)",
            ])
        } catch is CancellationError {
            job.setStage(.cancelled)
        } catch {
            AppLog.error(.reader, "Translation export failed", metadata: ["error": "\(error)"])
            job.setStage(.failed(error.localizedDescription))
        }
    }

    private struct PreparedExport {
        let writer: TranslationExportWriter
        /// Security-scoped URLs to hold while reading the book's pages.
        let accessURLs: [URL]
    }

    /// The book's pages and translations (translated first if needed), with
    /// the reader's edits laid over them.
    private func prepareTranslationExport(_ job: TranslationExportJob) async throws -> PreparedExport {
        let url = job.bookURL
        let target = job.options.target
        let isOpenBook = hasSource && currentSourceURL?.standardizedFileURL == url.standardizedFileURL
        let pages: [ComicPage]
        if isOpenBook {
            pages = source.pages
        } else {
            guard let volume = await loadVolumeForTranslation(url) else { throw TranslationExportError.unreadableBook }
            pages = volume.pages
        }
        guard !pages.isEmpty else { throw TranslationExportError.unreadableBook }
        try Task.checkCancellation()

        let seriesID = ReaderSeriesIdentity.make(for: url, opened: openedSourceURL, tempRoot: tempDir.url) ?? ""
        let accessURLs = [libraryScope.url, openedSourceURL, url].compactMap { $0 }
        let controller: TranslationController
        if isOpenBook {
            let (existing, isNew) = translationManager.controller(for: target)
            if isNew { setUp(existing, target: target, autoStart: false, restart: false) }
            controller = existing
        } else {
            let (existing, isNew) = translationManager.backgroundController(
                bookKey: url.standardizedFileURL.path,
                title: job.title,
                bookURL: url,
                target: target
            )
            // An idle one is set up again too, to pick up translations made
            // since (in the open book, say) from the cache.
            if isNew || !existing.hasActiveJob {
                // Read the way the series is read: the vertical layout's
                // translations are made over the strip.
                let layout = seriesPreferences.layout(forSeries: seriesID) ?? preferences.layout
                configure(existing, seriesID: seriesID, accessURLs: accessURLs)
                existing.reload(
                    pages: pages,
                    pageSizes: [],
                    scope: layout.isContinuous ? .strip : .page,
                    source: seriesPreferences.translationSource(forSeries: seriesID),
                    target: target,
                    mode: translationMode,
                    matchSpeechLevel: translationMatchesSpeechLevel,
                    enabled: true,
                    autoStart: false,
                    focusPage: 0
                )
            }
            controller = existing
        }
        await controller.cacheTask?.value
        try Task.checkCancellation()

        if job.options.untranslated == .translateFirst, controller.completedPageCount < controller.bookPageCount {
            job.waitOn(controller)
            if !controller.isWorking, controller.phase != .queued {
                translationManager.start(controller)
            }
            try await waitForTranslation(controller)
        }

        // Speech levels being matched on cached pages land in the export too.
        while controller.speechLevelProgress != nil {
            try await Task.sleep(for: .milliseconds(500))
        }

        // Taken at once: the controller may be cleared when its book closes.
        let machine = controller.pages
        let scope = controller.scope
        let edits = await exportEdits(pageIDs: pages.map(\.id), scope: scope, isOpenBook: isOpenBook)
        var translations: [String: TranslatedPage] = [:]
        for page in pages {
            guard let translated = machine[page.id] else { continue }
            translations[page.id] = edits[page.id]?.apply(to: translated, target: target) ?? translated
        }
        let hasText = translations.values.contains { page in
            page.bubbles.contains { !($0.translation ?? "").isEmpty }
        }
        guard hasText else { throw TranslationExportError.nothingTranslated }
        return PreparedExport(
            writer: TranslationExportWriter(pages: pages, translations: translations, scope: scope, format: job.options.format),
            accessURLs: accessURLs
        )
    }

    /// Until every page of `controller`'s book is translated. A job that stops
    /// short (an error, a missing language pack, stopped by the reader) ends
    /// the export with its reason; a paused one is waited for.
    private func waitForTranslation(_ controller: TranslationController) async throws {
        while controller.completedPageCount < controller.bookPageCount {
            try await Task.sleep(for: .milliseconds(500))
            if let notice = controller.notice {
                throw TranslationExportError.translationStopped(notice.message(locale: localization.locale))
            }
            if controller.phase == .idle, controller.completedPageCount < controller.bookPageCount {
                throw TranslationExportError.translationStopped(
                    String(localized: "Translation was stopped before the book was finished.", bundle: .localized)
                )
            }
        }
    }

    /// The reader's edits for the book: the open book's as they are in
    /// memory (the latest may not be on disk yet), any other's from disk.
    private func exportEdits(pageIDs: [String], scope: TranslationScope, isOpenBook: Bool) async -> [String: PageEdits] {
        if isOpenBook, translationEdits.scope == scope {
            var edits: [String: PageEdits] = [:]
            for id in pageIDs {
                if let pageEdits = translationEdits.edits(forPage: id) { edits[id] = pageEdits }
            }
            return edits
        }
        let store = dependencies.translationEditStore
        return await Task.detached(priority: .utility) {
            var edits: [String: PageEdits] = [:]
            for id in pageIDs {
                if let pageEdits = store.load(key: TranslationEditStore.key(pageID: id, scope: scope)) { edits[id] = pageEdits }
            }
            return edits
        }.value
    }

    /// Render and write, off the main actor; cancelling the job stops it
    /// between pages.
    private func writeTranslationExport(
        _ job: TranslationExportJob,
        prepared: PreparedExport,
        into folder: URL
    ) async throws -> TranslationExportWriter.Result {
        let writer = prepared.writer
        job.setStage(.exporting(done: 0, total: writer.pages.count))
        let name = TranslationExportWriter.safeFileName(
            "\(job.title) [\(job.options.target.displayName(in: localization.locale))]"
        )
        let accessed = ([folder] + prepared.accessURLs).filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let work = Task.detached(priority: .utility) {
            try await writer.write(into: folder, name: name) { done, total in
                await job.setStage(.exporting(done: done, total: total))
            }
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func exportTitle(for url: URL) -> String {
        if hasSource, currentSourceURL?.standardizedFileURL == url.standardizedFileURL, !source.title.isEmpty {
            return source.title
        }
        return SecurityScopedBookmark.isDirectory(url) ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}
