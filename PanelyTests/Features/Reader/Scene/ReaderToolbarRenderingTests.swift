import AppKit
import SwiftUI
import Testing
@testable import Panely

/// Hosts the real reader toolbar (`ReaderToolbarOverlay`), changes the
/// model under it and checks the controls on screen followed: which exist,
/// which are enabled, which are lit.
///
/// Each check renders the toolbar as one token per control, left to right
/// (see `shape`): `□` a button, `■` a lit (active) one, `·` a disabled one,
/// `▭` a wider control (the translation language menu), and `|` where a
/// gap separates groups.
@MainActor
struct ReaderToolbarRenderingTests {

    /// A translation arriving lights the translate button and names the
    /// language next to it. The toolbar reads `TranslationController.hasPages`,
    /// which flips only when the first page lands.
    @Test func translationArrivingLightsTheTranslateButton() async throws {
        let vm = SnapshotSampleContent.loadedViewModel(layout: .double, direction: .rightToLeft, pageCount: 24)
        vm.appLanguage = .english
        vm.translationTargetLanguage = .english
        // On, but the book's language isn't known yet: nothing to show.
        vm.translationEnabled = true
        let hosted = await host(vm)
        defer { hosted.close() }
        try await expectShape(in: hosted, "□ □ ■ | □ ■ □ □ □ □ | □ □ □ □ □ ▭ | · □ □ □", "translation on, nothing translated yet")

        // The controller takes the book's pages asynchronously; a language
        // set before that has no pages to load.
        try await waitUntil { vm.translation.bookPageCount == vm.source.pages.count }
        for (index, page) in TranslationSnapshotContent.pages.enumerated() {
            try vm.translationManager.store.save(
                TranslationSnapshotContent.translated(page),
                key: TranslationStore.key(pageID: vm.source.pages[index].id, from: .japanese, to: .english)
            )
        }
        vm.translation.setSource(.japanese)
        try await expectShape(in: hosted, "□ □ ■ | □ ■ □ □ □ □ | □ □ □ □ ■ ▭ | · □ □ □", "the cached translation loaded: translate button lit")
    }

    /// The bookmark button is lit on a bookmarked page — and goes dark again
    /// on the next one.
    @Test func bookmarkButtonFollowsPageTurns() async throws {
        let vm = SnapshotSampleContent.loadedViewModel()
        let book = try #require(vm.currentSourceURL)
        vm.pageBookmarks.pageBookmarksByBook[vm.positionKey(for: book)] = [PageBookmark(pageIndex: 3)]
        let hosted = await host(vm)
        defer { hosted.close() }
        //  open, pins | layout, direction, fit, zoom | favorite, bookmark,
        //  bookmark list, thumbnails | volume / page navigation
        try await expectShape(in: hosted, "□ □ ■ | ■ □ □ □ ■ □ □ □ □ □ | □ □ □ □ | · □ □ □", "page 1, not bookmarked")

        vm.currentPageIndex = 3
        try await expectShape(in: hosted, "□ □ ■ | ■ □ □ □ ■ □ □ □ □ □ | □ ■ □ □ | · □ □ □", "page 4, bookmarked: the bookmark button lit")

        vm.currentPageIndex = 4
        try await expectShape(in: hosted, "□ □ ■ | ■ □ □ □ ■ □ □ □ □ □ | □ □ □ □ | · □ □ □", "page 5, not bookmarked: dark again")
    }

    /// Stepping to the next volume enables "Previous Volume"; on the last
    /// one "Next Volume" is disabled.
    @Test func volumeButtonsFollowTheOpenVolume() async throws {
        let vm = SnapshotSampleContent.loadedViewModel()
        let hosted = await host(vm)
        defer { hosted.close() }
        try await expectShape(in: hosted, "□ □ ■ | ■ □ □ □ ■ □ □ □ □ □ | □ □ □ □ | · □ □ □", "Volume 1 of 3: no previous volume")

        vm.currentSourceURL = vm.siblings[1]
        vm.openedSourceURL = vm.siblings[1]
        try await expectShape(in: hosted, "□ □ ■ | ■ □ □ □ ■ □ □ □ □ □ | □ □ □ □ | □ □ □ □", "Volume 2 of 3: both directions")

        vm.currentSourceURL = vm.siblings[2]
        vm.openedSourceURL = vm.siblings[2]
        try await expectShape(in: hosted, "□ □ ■ | ■ □ □ □ ■ □ □ □ □ □ | □ □ □ □ | □ □ □ ·", "Volume 3 of 3: no next volume")
    }

    /// While hidden the toolbar keeps its last state, so page turns don't
    /// rebuild it. Showing it has to catch up with what happened meanwhile, and
    /// from there on it follows page turns again.
    @Test func aHiddenToolbarCatchesUpWhenShown() async throws {
        let vm = SnapshotSampleContent.loadedViewModel()
        let book = try #require(vm.currentSourceURL)
        vm.pageBookmarks.pageBookmarksByBook[vm.positionKey(for: book)] = [PageBookmark(pageIndex: 3)]
        let visibility = ToolbarVisibility()
        AppLocalization.shared.apply(.english)
        let hosted = await SnapshotRenderer.host(
            VisibilityDrivenToolbar(visibility: visibility)
                .environment(vm)
                .environment(ViewerController())
                .environment(\.locale, Locale(identifier: "en"))
                .padding(PanelySpacing.md),
            size: SnapshotRenderer.toolbarSize
        )
        defer { hosted.close() }
        let dark = "□ □ ■ | ■ □ □ □ ■ □ □ □ □ □ | □ □ □ □ | · □ □ □"
        let lit = "□ □ ■ | ■ □ □ □ ■ □ □ □ □ □ | □ ■ □ □ | · □ □ □"

        vm.currentPageIndex = 3
        visibility.shown = true
        try await expectShape(in: hosted, lit, "shown after turning to the bookmarked page while hidden")

        vm.currentPageIndex = 4
        try await expectShape(in: hosted, dark, "a page turn while shown")

        visibility.shown = false
        try await Task.sleep(for: .milliseconds(100))
        vm.currentPageIndex = 3
        try await Task.sleep(for: .milliseconds(100))
        visibility.shown = true
        try await expectShape(in: hosted, lit, "hidden, turned, shown again")
    }

    // MARK: - Helpers

    @Observable
    final class ToolbarVisibility {
        var shown = false
    }

    private struct VisibilityDrivenToolbar: View {
        let visibility: ToolbarVisibility

        var body: some View {
            ReaderToolbarOverlay(shown: visibility.shown)
        }
    }

    private func host(_ vm: ReaderViewModel) async -> SnapshotRenderer.HostedView {
        AppLocalization.shared.apply(.english)
        return await SnapshotRenderer.host(
            ReaderToolbarOverlay(shown: true)
                .environment(vm)
                .environment(ViewerController())
                .environment(\.locale, Locale(identifier: "en"))
                .padding(PanelySpacing.md),
            size: SnapshotRenderer.toolbarSize
        )
    }

    private func expectShape(
        in hosted: SnapshotRenderer.HostedView,
        _ expected: String,
        _ what: String
    ) async throws {
        try await hosted.settle(what, describe: { try "expected: \(expected)\ngot:      \(shape(in: hosted))" }) {
            try shape(in: hosted) == expected
        }
    }

    /// One token per control, left to right: `□` button, `■` lit button
    /// (mostly accent-filled), `·` disabled button (dimmed glyph, nothing
    /// near-white), `▭` anything wider than a toolbar button; `|` between
    /// groups.
    private func shape(in hosted: SnapshotRenderer.HostedView) throws -> String {
        let pixels = try hosted.capture()
        var tokens: [String] = []
        var previousMaxX: CGFloat?
        for frame in hosted.controlFrames() {
            if let previousMaxX, frame.minX - previousMaxX > 10 { tokens.append("|") }
            previousMaxX = frame.maxX
            let inner = frame.insetBy(dx: 4, dy: 4)
            let area = Int(inner.width * inner.height * pixels.scale * pixels.scale)
            if frame.width > 40 {
                tokens.append("▭")
            } else if pixels.accentPixels(in: inner) * 2 > area {
                tokens.append("■")
            } else if pixels.brightPixels(in: inner) < 10 {
                tokens.append("·")
            } else {
                tokens.append("□")
            }
        }
        return tokens.joined(separator: " ")
    }
}
