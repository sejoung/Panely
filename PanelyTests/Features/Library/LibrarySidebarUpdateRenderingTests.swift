import AppKit
import SwiftUI
import Testing
@testable import Panely

/// Hosts the real sidebar (`SidebarHost` over a `ReaderViewModel`), changes
/// the model the way reading does — turning pages, opening another book,
/// recording progress, bookmarking — and checks the rows on screen followed.
///
/// `LibrarySidebarRenderingTests` checks the tree's shape once; this checks
/// it *updates*. The perf pass moved the page index behind a closure read
/// only by the bookmark rows, precomputed each file row's active state and
/// badge, and memoized the cross-book bookmark list, so a row that renders
/// right once but never again would pass every model test.
///
/// Each check renders the outline as one line per row (see `shape`): the
/// disclosure marker, then `★` for a row drawn in the accent color (the
/// open book, the current page's bookmark), `◔` for a progress ring and
/// `●` for anything else in the badge slot (the finished mark, a bookmark
/// count).
@MainActor
struct LibrarySidebarUpdateRenderingTests {

    /// Rows of `SnapshotSampleContent.sidebarPopulatedViewModel`: Series A /
    /// Volume 01 open on page 7 (a saved position, hence its ring), pinned
    /// as a favorite, with bookmarks on pages 4, 9 and 16.
    ///
    ///     ▾ Favorites
    ///       · Series A · Volume 01      (the open book)
    ///     ▾ Bookmarks
    ///       · Page 4
    ///       · Page 9
    ///       · Page 16
    ///     ▾ Files
    ///       ▸ One-shots
    ///       ▾ Series A
    ///         · Volume 01                (the open book)
    ///         · Volume 02
    ///         · Volume 03
    ///       ▸ Series B
    private static func populatedShape(
        bookmarks: String = noBookmarkHighlighted,
        volume02: String = "",
        otherBooks: String = ""
    ) -> String {
        """
        ▾
          · ★
        ▾
        \(bookmarks)\(otherBooks)
        ▾
          ▸
          ▾
            · ★ ◔
            ·\(volume02)
            ·
          ▸
        """
    }

    private static let noBookmarkHighlighted = """
          ·
          ·
          ·
        """

    /// The current page's bookmark is drawn in the accent color — and moves
    /// with the page. `CurrentBookBookmarkRow` reads the page through a
    /// closure so a page turn re-renders only the bookmark rows.
    @Test func currentBookmarkHighlightFollowsPageTurns() async throws {
        let library = try LibraryFixture()
        let vm = SnapshotSampleContent.sidebarPopulatedViewModel(library: library)
        let hosted = await host(vm)
        defer { hosted.close() }
        try await expectShape(in: hosted, Self.populatedShape(), "page 7: no bookmark highlighted")

        vm.currentPageIndex = 8
        try await expectShape(in: hosted, Self.populatedShape(bookmarks: """
              ·
              · ★
              ·
            """), "page 9: its bookmark highlighted")

        vm.currentPageIndex = 15
        try await expectShape(in: hosted, Self.populatedShape(bookmarks: """
              ·
              ·
              · ★
            """), "page 16: the highlight moved to its bookmark")

        vm.currentPageIndex = 3
        try await expectShape(in: hosted, Self.populatedShape(bookmarks: """
              · ★
              ·
              ·
            """), "page 4: the highlight moved back up")
    }

    /// Opening a book elsewhere in the library moves the active row to it
    /// and expands the folder it's in; the old book's bookmarks move to
    /// "Bookmarks in Other Books".
    @Test func openingAnotherBookMovesTheActiveRowAndRevealsIt() async throws {
        let library = try LibraryFixture()
        let vm = SnapshotSampleContent.sidebarPopulatedViewModel(library: library)
        let hosted = await host(vm)
        defer { hosted.close() }
        try await expectShape(in: hosted, Self.populatedShape())

        let other = library.root.appendingPathComponent("Series B/Volume 02.cbz")
        vm.currentSourceURL = other
        vm.openedSourceURL = other

        //     ▾ Favorites
        //       · Series A · Volume 01
        //     ▾ Bookmarks in Other Books
        //       ▸ Series A / Volume 01        (3 bookmarks)
        //     ▾ Files
        //       ▸ One-shots
        //       ▾ Series A
        //         · Volume 01                 (its saved position)
        //         · Volume 02
        //         · Volume 03
        //       ▾ Series B
        //         · Volume 01
        //         · Volume 02                 (now open)
        try await expectShape(in: hosted, """
            ▾
              ·
            ▾
              ▸ ●
            ▾
              ▸
              ▾
                · ◔
                ·
                ·
              ▾
                ·
                · ★
            """, "Series B expanded with Volume 02 active; Series A / Volume 01 under Bookmarks in Other Books")
    }

    /// Recording progress puts a ring on the book's row; finishing it turns
    /// that into the finished mark. File rows get their badge precomputed by
    /// the parent, so this is the parent re-rendering them.
    @Test func recordedProgressUpdatesTheReadingBadge() async throws {
        let library = try LibraryFixture()
        let vm = SnapshotSampleContent.sidebarPopulatedViewModel(library: library)
        let hosted = await host(vm)
        defer { hosted.close() }
        try await expectShape(in: hosted, Self.populatedShape())

        let volume2 = library.root.appendingPathComponent("Series A/Volume 02.cbz")
        func record(page: Int, finished: Bool) {
            vm.readingProgress.flushImmediately(
                for: volume2, opened: vm.openedSourceURL, tempRoot: vm.tempDir.url,
                page: page, total: 24, finished: finished
            )
        }

        record(page: 5, finished: false)
        try await expectShape(in: hosted, Self.populatedShape(volume02: " ◔"), "Volume 02 shows a progress ring")

        record(page: 23, finished: true)
        try await expectShape(in: hosted, Self.populatedShape(volume02: " ●"), "Volume 02 shows the finished mark")
    }

    /// Bookmarking a page of another book adds the "Bookmarks in Other
    /// Books" section with that book. The list is memoized on the bookmark
    /// store's revision.
    @Test func bookmarkInAnotherBookAddsItsSection() async throws {
        let library = try LibraryFixture()
        let vm = SnapshotSampleContent.sidebarPopulatedViewModel(library: library)
        let hosted = await host(vm)
        defer { hosted.close() }
        try await expectShape(in: hosted, Self.populatedShape())

        let otherKey = vm.positionKey(for: library.root.appendingPathComponent("Series B/Volume 01.cbz"))
        _ = vm.pageBookmarks.togglePageBookmark(key: otherKey, pageIndex: 2)

        // The book's row: collapsed, its bookmark count in the badge slot.
        try await expectShape(in: hosted, Self.populatedShape(otherBooks: """

            ▾
              ▸ ●
            """), "a Bookmarks in Other Books section listing Series B / Volume 01")
    }

    // MARK: - Helpers

    private func host(_ vm: ReaderViewModel) async -> SnapshotRenderer.HostedView {
        AppLocalization.shared.apply(.english)
        return await SnapshotRenderer.host(
            SidebarHost(requestFocus: {})
                .environment(vm)
                .environment(\.locale, Locale(identifier: "en")),
            size: SnapshotRenderer.sidebarSize
        )
    }

    /// Waits for the sidebar to render `expected` (see `shape`).
    private func expectShape(
        in hosted: SnapshotRenderer.HostedView,
        _ expected: String,
        _ what: String = "the sidebar to render the fixture"
    ) async throws {
        try await hosted.settle(what, describe: { try "expected:\n\(expected)\n\ngot:\n\(shape(in: hosted))" }) {
            try shape(in: hosted) == expected
        }
    }

    /// One line per outline row: indent = level, `▸`/`▾` folder or section
    /// collapsed/expanded, `·` leaf; then `★` if the row's label is in the
    /// accent color, `◔` if its badge slot holds a progress ring (drawn in
    /// the accent color), `●` if it holds anything else (the finished mark, a
    /// bookmark count).
    private func shape(in hosted: SnapshotRenderer.HostedView) throws -> String {
        guard let outline = hosted.firstSubview(of: NSOutlineView.self) else { return "(no outline)" }
        let pixels = try hosted.capture()
        return (0..<outline.numberOfRows).map { row in
            let item = outline.item(atRow: row)
            let level = outline.level(forRow: row)
            var line = String(repeating: "  ", count: level)
            line += outline.isExpandable(item) ? (outline.isItemExpanded(item) ? "▾" : "▸") : "·"
            guard level > 0 else { return line }

            let rect = hosted.frameInHost(of: outline, rect: outline.rect(ofRow: row))
            // The badge sits at the trailing edge; no name in the fixture
            // reaches it.
            let badgeSlot = CGRect(x: rect.maxX - 40, y: rect.minY, width: 36, height: rect.height)
            let label = CGRect(x: rect.minX, y: rect.minY, width: badgeSlot.minX - rect.minX, height: rect.height)
            let background = pixels.color(at: CGPoint(x: rect.minX + 2, y: rect.midY))
            if pixels.accentPixels(in: label) >= 12 { line += " ★" }
            if pixels.accentPixels(in: badgeSlot) >= 6 {
                line += " ◔"
            } else if pixels.inkPixels(in: badgeSlot, over: background) >= 20 {
                line += " ●"
            }
            return line
        }
        .joined(separator: "\n")
    }
}
