import AppKit
import SwiftUI
import Testing
@testable import Panely

/// Hosts the real page-thumbnail panel (`ThumbnailSidebarHost`) for a short
/// book and checks it follows reading: the current page's thumbnail is
/// outlined and numbered in the accent color, and translated pages get a
/// badge as their translation lands.
///
/// Each check renders the panel as one token per thumbnail, top to bottom
/// (see `shape`): `□` a page, `■` the current one, with `ᵀ` after a page
/// carrying the translated badge. Three pages fit without scrolling, so
/// the thumbnails stay put while the current page moves.
@MainActor
struct ThumbnailSidebarRenderingTests {

    @Test func currentThumbnailFollowsPageTurns() async throws {
        let vm = SnapshotSampleContent.loadedViewModel(thumbnailSidebarVisible: true, pageCount: 3)
        let hosted = await host(vm)
        defer { hosted.close() }
        try await expectShape(in: hosted, "■ □ □", "page 1 current")

        vm.currentPageIndex = 2
        try await expectShape(in: hosted, "□ □ ■", "page 3 current")

        vm.currentPageIndex = 1
        try await expectShape(in: hosted, "□ ■ □", "page 2 current")
    }

    @Test func translatedPagesGetTheirBadge() async throws {
        let vm = SnapshotSampleContent.loadedViewModel(thumbnailSidebarVisible: true, pageCount: 3)
        vm.appLanguage = .english
        vm.translationTargetLanguage = .english
        vm.translationEnabled = true
        let hosted = await host(vm)
        defer { hosted.close() }
        try await expectShape(in: hosted, "■ □ □", "nothing translated yet")

        // The controller takes the book's pages asynchronously; a language
        // set before that has no pages to load.
        try await waitUntil { vm.translation.bookPageCount == vm.source.pages.count }
        try vm.translationManager.store.save(
            TranslationSnapshotContent.translated(TranslationSnapshotContent.pages[0]),
            key: TranslationStore.key(pageID: vm.source.pages[1].id, from: .japanese, to: .english)
        )
        vm.translation.setSource(.japanese)
        try await expectShape(in: hosted, "■ □ᵀ □", "page 2's cached translation loaded: its badge")    }

    // MARK: - Helpers

    private static let size = CGSize(width: 148, height: 720)

    private func host(_ vm: ReaderViewModel) async -> SnapshotRenderer.HostedView {
        AppLocalization.shared.apply(.english)
        return await SnapshotRenderer.host(
            ThumbnailSidebarHost(requestFocus: {})
                .environment(vm)
                .environment(\.locale, Locale(identifier: "en")),
            size: Self.size
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

    /// One token per thumbnail (every control below the header's close
    /// button): `■` if its page number is in the accent color, else `□`;
    /// then `ᵀ` if its top-right corner holds the accent-filled badge.
    private func shape(in hosted: SnapshotRenderer.HostedView) throws -> String {
        let pixels = try hosted.capture()
        let cells = hosted.controlFrames().filter { $0.width > 100 }
        return cells.map { cell in
            // The page number under the thumbnail.
            let number = CGRect(x: cell.minX, y: cell.maxY - 16, width: cell.width, height: 16)
            // Inside the outline (2 pt, so ≤ 1 pt inside the edge), where
            // the badge sits: 4 pt in from the corner, ~18 pt across.
            let badge = CGRect(x: cell.maxX - 24, y: cell.minY + 4, width: 20, height: 20)
            var token = pixels.accentPixels(in: number) >= 12 ? "■" : "□"
            if pixels.accentPixels(in: badge) >= 300 { token += "ᵀ" }
            return token
        }
        .joined(separator: " ")
    }
}
