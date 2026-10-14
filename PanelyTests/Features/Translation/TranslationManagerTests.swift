import Foundation
import Testing
@testable import Panely

/// A job is one book in one language, and jobs outlive the open book. These
/// cover the bookkeeping: per-language controllers for the open book, keeping
/// work alive in the background, and handing it back on reopen.
@MainActor
struct TranslationManagerTests {
    private func makeManager() throws -> TranslationManager {
        TranslationManager(store: try makeTemporaryTranslationStore(), defaults: InMemoryKeyValueStore())
    }

    /// The open book's controller for `target`, set up with work left.
    @discardableResult
    private func configured(_ manager: TranslationManager, _ target: TranslationLanguage) -> TranslationController {
        let controller = manager.controller(for: target).controller
        controller.reload(
            pages: Fixture.makeImagePages(count: 2), pageSizes: [], scope: .page, source: .japanese, target: target,
            includeSoundEffects: false, enabled: true, autoStart: false, focusPage: 0
        )
        return controller
    }

    /// An active job without running the real pipeline: parked in the queue.
    private func queuedJob(_ manager: TranslationManager, _ target: TranslationLanguage) -> TranslationController {
        let controller = configured(manager, target)
        controller.markQueued()
        return controller
    }

    @Test func eachLanguageIsItsOwnController() throws {
        let manager = try makeManager()
        manager.beginBook(key: "/books/a.cbz", title: "A", url: nil)
        let korean = configured(manager, .korean)
        let english = configured(manager, .english)

        #expect(korean !== english)
        #expect(manager.controller(for: .korean).controller === korean)
        #expect(!manager.controller(for: .korean).isNew)

        manager.setDisplayTarget(.english)
        #expect(manager.current === english)
        manager.setDisplayTarget(.korean)
        #expect(manager.current === korean)
    }

    @Test func otherLanguagesOfTheOpenBookCountAsBackgroundJobs() throws {
        let manager = try makeManager()
        manager.beginBook(key: "/books/a.cbz", title: "A", url: nil)
        manager.setDisplayTarget(.korean)
        _ = configured(manager, .korean)
        let english = queuedJob(manager, .english)

        #expect(manager.backgroundJobs.contains { $0 === english })
        #expect(!manager.backgroundJobs.contains { $0 === manager.current })
    }

    @Test func openingAnotherBookKeepsActiveJobsAndDropsIdleOnes() throws {
        let manager = try makeManager()
        manager.beginBook(key: "/books/a.cbz", title: "A", url: nil)
        let english = queuedJob(manager, .english)
        _ = configured(manager, .korean) // idle

        manager.beginBook(key: "/books/b.cbz", title: "B", url: nil)

        #expect(manager.openBook.isEmpty)
        #expect(manager.background.count == 1)
        #expect(manager.background.first === english)
        #expect(manager.backgroundJobs.map { $0.label(locale: Locale(identifier: "en")) } == ["A → English"])
    }

    @Test func reopeningTheBookReattachesItsJobs() throws {
        let manager = try makeManager()
        manager.beginBook(key: "/books/a.cbz", title: "A", url: nil)
        let english = queuedJob(manager, .english)
        manager.beginBook(key: "/books/b.cbz", title: "B", url: nil)

        manager.beginBook(key: "/books/a.cbz", title: "A", url: nil)

        #expect(manager.openBook.first === english)
        #expect(manager.background.isEmpty)
        #expect(manager.controller(for: .english).controller === english)
    }

    @Test func stoppingABackgroundJobDropsIt() throws {
        let manager = try makeManager()
        manager.beginBook(key: "/books/a.cbz", title: "A", url: nil)
        let job = queuedJob(manager, .english)
        manager.beginBook(key: "/books/b.cbz", title: "B", url: nil)

        manager.stop(job)

        #expect(manager.background.isEmpty)
    }

    @Test func backgroundControllersAreReusedPerBookAndLanguage() throws {
        let manager = try makeManager()
        let made = manager.backgroundController(bookKey: "/books/v2.cbz", title: "v2", bookURL: nil, target: .korean)
        made.controller.reload(
            pages: Fixture.makeImagePages(count: 1), pageSizes: [], scope: .page, source: .japanese, target: .korean,
            includeSoundEffects: false, enabled: true, autoStart: false, focusPage: 0
        )
        let again = manager.backgroundController(bookKey: "/books/v2.cbz", title: "v2", bookURL: nil, target: .korean)
        let otherLanguage = manager.backgroundController(bookKey: "/books/v2.cbz", title: "v2", bookURL: nil, target: .english)

        #expect(made.isNew)
        #expect(!again.isNew)
        #expect(made.controller === again.controller)
        #expect(otherLanguage.isNew)
    }

    @Test func pausingAQueuedJobTakesItOutOfTheQueue() throws {
        let manager = try makeManager()
        manager.beginBook(key: "/books/a.cbz", title: "A", url: nil)
        let job = queuedJob(manager, .korean)

        manager.pause(job)

        #expect(job.phase == .paused)
        #expect(job.hasActiveJob)
    }

    @Test func aBookThatMustStayOpenPausesWhenClosedAndResumesOnReturn() throws {
        let manager = try makeManager()
        manager.beginBook(key: "/tmp/extracted/vol1", title: "vol1", url: nil)
        let job = queuedJob(manager, .korean)
        job.requiresOpenBook = true

        manager.beginBook(key: "/books/b.cbz", title: "B", url: nil)

        // Paused (not failed) and kept in the list, flagged as waiting for the book.
        #expect(job.phase == .paused)
        #expect(job.isWaitingForBookToReopen)
        #expect(manager.backgroundJobs.count == 1)
        // Can't run without its pages.
        manager.start(job)
        #expect(job.phase == .paused)

        manager.beginBook(key: "/tmp/extracted/vol1", title: "vol1", url: nil)
        #expect(!job.isWaitingForBookToReopen)
    }

    @Test func aFailedBackgroundJobStaysListedUntilDismissed() throws {
        let manager = try makeManager()
        let volume = manager.backgroundController(bookKey: "/books/v2.cbz", title: "v2", bookURL: nil, target: .korean).controller
        volume.notice = .failed("The file couldn't be opened.")

        #expect(manager.backgroundJobs.map(\.title) == ["v2"])

        manager.stop(volume)

        #expect(manager.backgroundJobs.isEmpty)
        #expect(volume.notice == nil)
    }

    @Test func withNoBookOpenTheCurrentControllerIsAnEmptyPlaceholder() throws {
        let manager = try makeManager()
        manager.beginBook(key: "/books/a.cbz", title: "A", url: nil)
        _ = queuedJob(manager, .korean)

        manager.detachOpenBook()

        #expect(manager.current.bookKey.isEmpty)
        #expect(manager.current.pages.isEmpty)
        #expect(manager.backgroundJobs.count == 1)
    }
}
