import CoreGraphics
import Foundation
import Observation
import Testing
@testable import Panely

/// `pages` is written only through `setPage`/`setPages`/`removeAllPages`,
/// which keep `hasPages` and `pageRevisions` in step. The viewer keeps what
/// it builds from a page by its revision, so a page changing without a new
/// revision shows stale balloons; and views reading `hasPages` must not
/// re-render on every balloon.
@MainActor
struct TranslationControllerPageStateTests {
    private struct Snapshot {
        let pages: [String: TranslatedPage]
        let revisions: [String: Int]

        @MainActor init(_ controller: TranslationController) {
            pages = controller.pages
            revisions = controller.pageRevisions
        }
    }

    /// The invariants, and — against an earlier snapshot — that any page
    /// whose entry changed has a new revision.
    private func checkInStep(_ controller: TranslationController, since earlier: Snapshot?, _ step: String) {
        #expect(controller.hasPages == !controller.pages.isEmpty, "\(step): hasPages")
        #expect(Set(controller.pageRevisions.keys) == Set(controller.pages.keys), "\(step): revisions cover the pages")
        guard let earlier else { return }
        for (id, page) in controller.pages where earlier.pages[id] != page {
            #expect(controller.pageRevisions[id] != earlier.revisions[id], "\(step): \(id) changed without a new revision")
        }
    }

    private func reload(_ controller: TranslationController, pages: [ComicPage], target: TranslationLanguage = .korean, match: Bool) {
        controller.reload(
            pages: pages, pageSizes: [], scope: .page, source: .japanese, target: target,
            matchSpeechLevel: match, enabled: true, autoStart: false, focusPage: 0
        )
    }

    /// Every way the controller's pages change outside a job: the cache
    /// loading, speech levels matched page by page, pages translated again,
    /// the language changed, the cache cleared, the book closed.
    @Test func everyChangeToAPageGetsANewRevision() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 4)
        for index in 0..<3 {
            try store.save(
                makeTranslationTestPage(pageIndex: index, bubbles: 1, label: "번역"),
                key: TranslationStore.key(pageID: pages[index].id, from: .japanese, to: .korean)
            )
        }
        let gate = TranslationPermitGate()
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore())
        controller.makeSpeechLevelCorrector = { _, _ in GatedSpeechLevelCorrector(gate: gate) }
        controller.requestStart = {}
        checkInStep(controller, since: nil, "new")
        #expect(!controller.hasPages)

        reload(controller, pages: pages, match: true)
        checkInStep(controller, since: nil, "reload")
        await controller.cacheTask?.value
        #expect(controller.pages.count == 3)
        checkInStep(controller, since: nil, "cache loaded")

        // Matched one page at a time, each saved over its entry.
        for done in 1...3 {
            let before = Snapshot(controller)
            await gate.release()
            try await waitUntil { controller.pages.values.filter { $0.speechLevelChecked == true }.count == done }
            checkInStep(controller, since: before, "matched \(done)")
            let changed = controller.pages.filter { before.pages[$0.key] != $0.value }.map(\.key)
            #expect(changed.count == 1, "one page per match")
            let unchanged = controller.pageRevisions.filter { !changed.contains($0.key) }
            #expect(unchanged == before.revisions.filter { !changed.contains($0.key) }, "the others keep theirs")
        }
        try await waitUntil { controller.speechLevelProgress == nil }

        var before = Snapshot(controller)
        await controller.translateAgain(pageIndices: [1])
        checkInStep(controller, since: before, "translate one again")
        #expect(controller.pages[pages[1].id] == nil && controller.hasPages)
        #expect(controller.pageRevisions.filter { $0.key != pages[0].id && $0.key != pages[2].id }.isEmpty)
        #expect(controller.pageRevisions[pages[0].id] == before.revisions[pages[0].id])

        before = Snapshot(controller)
        controller.setSource(.chineseSimplified)
        checkInStep(controller, since: before, "language changed")
        await controller.cacheTask?.value
        #expect(!controller.hasPages)
        controller.setSource(.japanese)
        await controller.cacheTask?.value
        #expect(controller.pages.count == 2)
        checkInStep(controller, since: nil, "language back")
        for (id, revision) in controller.pageRevisions {
            #expect(before.revisions[id] != revision, "reloaded pages are new")
        }

        _ = await controller.clearCache()
        checkInStep(controller, since: nil, "cache cleared")
        #expect(!controller.hasPages)

        reload(controller, pages: pages, match: false)
        controller.clear()
        checkInStep(controller, since: nil, "closed")
        #expect(controller.pageRevisions.isEmpty)
        await gate.open()
    }

    /// Revisions are unique across controllers: the viewer keys the other
    /// languages' balloons by them too.
    @Test func revisionsAreUniqueAcrossControllers() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 3)
        for page in pages {
            for target in [TranslationLanguage.korean, .english] {
                try store.save(makeTranslationTestPage(pageIndex: 0, bubbles: 1, label: target.rawValue), key: TranslationStore.key(pageID: page.id, from: .japanese, to: target))
            }
        }
        let korean = TranslationController(store: store, defaults: InMemoryKeyValueStore())
        let english = TranslationController(store: store, defaults: InMemoryKeyValueStore())
        reload(korean, pages: pages, match: false)
        reload(english, pages: pages, target: .english, match: false)
        await korean.cacheTask?.value
        await english.cacheTask?.value

        let all = Array(korean.pageRevisions.values) + Array(english.pageRevisions.values)
        #expect(all.count == 6)
        #expect(Set(all).count == 6)
    }

    /// `hasPages` is observed on its own so the toolbar and menus don't
    /// re-render with every balloon: it notifies when it flips, and only then.
    @Test func hasPagesNotifiesOnlyWhenItFlips() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 2)
        for index in 0..<2 {
            try store.save(makeTranslationTestPage(pageIndex: index, bubbles: 1, label: "번역"), key: TranslationStore.key(pageID: pages[index].id, from: .japanese, to: .korean))
        }
        let gate = TranslationPermitGate()
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore())
        controller.makeSpeechLevelCorrector = { _, _ in GatedSpeechLevelCorrector(gate: gate) }
        controller.requestStart = {}

        let loaded = ObservationProbe { _ = controller.hasPages }
        reload(controller, pages: pages, match: true)
        await controller.cacheTask?.value
        #expect(controller.hasPages)
        #expect(loaded.fired)

        // A page's content changes (its speech level matched): `pages`
        // observers hear of it, `hasPages` observers don't.
        let flag = ObservationProbe { _ = controller.hasPages }
        let content = ObservationProbe { _ = controller.pages }
        await gate.release()
        try await waitUntil { controller.pages.values.contains { $0.speechLevelChecked == true } }
        #expect(content.fired)
        #expect(!flag.fired)

        // One of two pages goes: still something to show.
        let stillFlag = ObservationProbe { _ = controller.hasPages }
        await controller.translateAgain(pageIndices: [0])
        #expect(controller.hasPages)
        #expect(!stillFlag.fired)

        // The last one goes: nothing to show.
        let emptied = ObservationProbe { _ = controller.hasPages }
        await controller.translateAgain(pageIndices: [1])
        #expect(!controller.hasPages)
        #expect(emptied.fired)
        await gate.open()
    }
}

/// Whether anything `read` touched changed since the probe was made.
@MainActor
final class ObservationProbe {
    private(set) var fired = false

    init(_ read: @escaping @MainActor () -> Void) {
        arm(read)
    }

    private func arm(_ read: @escaping @MainActor () -> Void) {
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            // Called synchronously on the mutating thread (main here).
            MainActor.assumeIsolated { self?.fired = true }
        }
    }
}
