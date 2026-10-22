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

    private func reload(_ controller: TranslationController, pages: [ComicPage], target: TranslationLanguage = .korean) {
        controller.reload(
            pages: pages, pageSizes: [], scope: .page, source: .japanese, target: target,
            enabled: true, autoStart: false, focusPage: 0
        )
    }

    /// A controller whose jobs read `analyzer`'s balloons and translate them
    /// one pass of `gate` at a time.
    private func makeController(store: TranslationStore, gate: TranslationPermitGate, analyzer: StubPageAnalyzer = StubPageAnalyzer()) -> TranslationController {
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore(), translator: ScriptedTranslator(gate: gate))
        controller.makeAnalyzer = { _, _ in analyzer }
        controller.requestStart = {}
        return controller
    }

    private func translatedCount(_ page: TranslatedPage?) -> Int {
        page?.bubbles.filter { $0.translation != nil }.count ?? 0
    }

    /// Every way the controller's pages change: the cache loading, a job
    /// filling a page in balloon by balloon, pages translated again, the
    /// language changed, the cache cleared, the book closed.
    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func everyChangeToAPageGetsANewRevision() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 4)
        for index in 0..<3 {
            try store.save(
                makeTranslationTestPage(pageIndex: index, bubbles: 1, label: "번역"),
                key: TranslationStore.key(pageID: pages[index].id, from: .japanese, to: .korean)
            )
        }
        let gate = TranslationPermitGate()
        let controller = makeController(store: store, gate: gate)
        checkInStep(controller, since: nil, "new")
        #expect(!controller.hasPages)

        reload(controller, pages: pages)
        checkInStep(controller, since: nil, "reload")
        await controller.cacheTask?.value
        #expect(controller.pages.count == 3)
        checkInStep(controller, since: nil, "cache loaded")

        // The job finds page 3's balloons, then translates them one at a time.
        var before = Snapshot(controller)
        controller.start()
        try await waitUntil { controller.pages[pages[3].id] != nil }
        checkInStep(controller, since: before, "balloons found")
        for done in 1...3 {
            let before = Snapshot(controller)
            await gate.release()
            try await waitUntil { translatedCount(controller.pages[pages[3].id]) == done }
            checkInStep(controller, since: before, "translated \(done)")
            let changed = controller.pages.filter { before.pages[$0.key] != $0.value }.map(\.key)
            #expect(changed == [pages[3].id], "only the page being translated")
            let unchanged = controller.pageRevisions.filter { !changed.contains($0.key) }
            #expect(unchanged == before.revisions.filter { !changed.contains($0.key) }, "the others keep theirs")
        }
        try await waitUntil { controller.phase == .idle }
        #expect(controller.completedPageIndices == [0, 1, 2, 3])

        before = Snapshot(controller)
        await controller.translateAgain(pageIndices: [1])
        checkInStep(controller, since: before, "translate one again")
        #expect(controller.pages[pages[1].id] == nil && controller.hasPages)
        #expect(Set(controller.pageRevisions.keys) == [pages[0].id, pages[2].id, pages[3].id])
        #expect(controller.pageRevisions[pages[0].id] == before.revisions[pages[0].id])

        before = Snapshot(controller)
        controller.setSource(.chineseSimplified)
        checkInStep(controller, since: before, "language changed")
        await controller.cacheTask?.value
        #expect(!controller.hasPages)
        controller.setSource(.japanese)
        await controller.cacheTask?.value
        // Page 3 too: the job saved it.
        #expect(controller.pages.count == 3)
        checkInStep(controller, since: nil, "language back")
        for (id, revision) in controller.pageRevisions {
            #expect(before.revisions[id] != revision, "reloaded pages are new")
        }

        _ = await controller.clearCache()
        checkInStep(controller, since: nil, "cache cleared")
        #expect(!controller.hasPages)

        reload(controller, pages: pages)
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
        reload(korean, pages: pages)
        reload(english, pages: pages, target: .english)
        await korean.cacheTask?.value
        await english.cacheTask?.value

        let all = Array(korean.pageRevisions.values) + Array(english.pageRevisions.values)
        #expect(all.count == 6)
        #expect(Set(all).count == 6)
    }

    /// `hasPages` is observed on its own so the toolbar and menus don't
    /// re-render with every balloon: it notifies when it flips, and only then.
    @Test(.enabled(if: TranslationController.isSupportedOnThisMac))
    func hasPagesNotifiesOnlyWhenItFlips() async throws {
        let store = try makeTemporaryTranslationStore()
        let pages = Fixture.makeImagePages(count: 3)
        for index in 0..<2 {
            try store.save(makeTranslationTestPage(pageIndex: index, bubbles: 1, label: "번역"), key: TranslationStore.key(pageID: pages[index].id, from: .japanese, to: .korean))
        }
        let gate = TranslationPermitGate()
        let controller = makeController(store: store, gate: gate)

        let loaded = ObservationProbe { _ = controller.hasPages }
        reload(controller, pages: pages)
        await controller.cacheTask?.value
        #expect(controller.hasPages)
        #expect(loaded.fired)

        // A page's content changes (a balloon translated): `pages`
        // observers hear of it, `hasPages` observers don't.
        controller.start()
        try await waitUntil { controller.pages[pages[2].id] != nil }
        let flag = ObservationProbe { _ = controller.hasPages }
        let content = ObservationProbe { _ = controller.pages }
        await gate.release()
        try await waitUntil { translatedCount(controller.pages[pages[2].id]) == 1 }
        #expect(content.fired)
        #expect(!flag.fired)
        await gate.open()
        try await waitUntil { controller.phase == .idle }

        // Two of three pages go: still something to show.
        let stillFlag = ObservationProbe { _ = controller.hasPages }
        await controller.translateAgain(pageIndices: [0, 2])
        #expect(controller.hasPages)
        #expect(!stillFlag.fired)

        // The last one goes: nothing to show.
        let emptied = ObservationProbe { _ = controller.hasPages }
        await controller.translateAgain(pageIndices: [1])
        #expect(!controller.hasPages)
        #expect(emptied.fired)
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
