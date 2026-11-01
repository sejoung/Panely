import AppKit
import SwiftUI
import Testing
@testable import Panely

/// Renders the real `LibrarySidebar` off-screen over a fixture library and
/// checks the outline AppKit actually built, not just `LibrarySidebarModel`.
///
/// The model tests can't catch a tree that scans fine but draws flat: an
/// `.equatable()` around the folder rows once hid each `DisclosureGroup`
/// from the `List` outline, so folders lost their disclosure and nothing
/// below the top level showed — with every model test still green.
@MainActor
struct LibrarySidebarRenderingTests {
    /// Fixture:
    ///
    ///     Library/
    ///       Loose.cbz
    ///       One-shots/   Tale.cbz
    ///       Series A/    Volume 01.cbz (open) · Volume 02.cbz · Arc/ Extra.cbz
    ///       Series B/    Volume 01.cbz · Volume 02.cbz
    private struct Library {
        let root: URL
        let activeBook: URL
        let seriesB: URL

        init(in tempRoot: URL) throws {
            root = tempRoot.appendingPathComponent("Library", isDirectory: true)
            let oneShots = root.appendingPathComponent("One-shots", isDirectory: true)
            let seriesA = root.appendingPathComponent("Series A", isDirectory: true)
            let arc = seriesA.appendingPathComponent("Arc", isDirectory: true)
            seriesB = root.appendingPathComponent("Series B", isDirectory: true)
            for dir in [oneShots, arc, seriesB] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            _ = try Fixture.writeFile(root.appendingPathComponent("Loose.cbz"))
            _ = try Fixture.writeFile(oneShots.appendingPathComponent("Tale.cbz"))
            _ = try Fixture.writeFile(seriesA.appendingPathComponent("Volume 01.cbz"))
            _ = try Fixture.writeFile(seriesA.appendingPathComponent("Volume 02.cbz"))
            _ = try Fixture.writeFile(arc.appendingPathComponent("Extra.cbz"))
            _ = try Fixture.writeFile(seriesB.appendingPathComponent("Volume 01.cbz"))
            _ = try Fixture.writeFile(seriesB.appendingPathComponent("Volume 02.cbz"))
            activeBook = seriesA.appendingPathComponent("Volume 01.cbz")
        }
    }

    /// The Files section with the open book's folder expanded, as the user
    /// sees it right after opening Series A / Volume 01. One line per row:
    /// indent = outline level, `▸` collapsed folder, `▾` expanded, `·` leaf.
    ///
    ///     ▾ Files
    ///       · Loose
    ///       ▸ One-shots
    ///       ▾ Series A
    ///         ▸ Arc
    ///         · Volume 01
    ///         · Volume 02
    ///       ▸ Series B
    private static let openBookShape = """
        ▾
          ·
          ▸
          ▾
            ▸
            ·
            ·
          ▸
        """

    @Test func foldersRenderAsExpandableRowsWithTheOpenBookRevealed() async throws {
        let tempRoot = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let library = try Library(in: tempRoot)

        let hosted = await host(library)
        defer { hosted.close() }

        let outline = try await settledOutline(in: hosted, rows: 8)
        #expect(Self.shape(of: outline) == Self.openBookShape)
    }

    @Test func expandingAFolderShowsItsChildren() async throws {
        let tempRoot = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let library = try Library(in: tempRoot)

        let hosted = await host(library)
        defer { hosted.close() }
        let outline = try await settledOutline(in: hosted, rows: 8)

        // Series B is the last top-level row (see `openBookShape`).
        let seriesBRow = 7
        try #require(outline.level(forRow: seriesBRow) == 1)
        outline.expandItem(outline.item(atRow: seriesBRow))

        let expanded = try await settledOutline(in: hosted, rows: 10)
        #expect(Self.shape(of: expanded) == """
            ▾
              ·
              ▸
              ▾
                ▸
                ·
                ·
              ▾
                ·
                ·
            """)
    }

    /// The overlay sidebar is mounted per reveal over a model that outlives
    /// it: the second mount must draw the same outline straight away, with
    /// the folder the user expanded still open and no rescan.
    @Test func remountingOverTheSameModelKeepsTheTreeWithoutRescanning() async throws {
        let tempRoot = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let library = try Library(in: tempRoot)
        let model = LibrarySidebarModel()
        let loader = CountingLiveLoader()
        let token = UUID()

        let first = await host(library, model: model, loader: loader, refreshToken: token)
        let outline = try await settledOutline(in: first, rows: 8)
        outline.expandItem(outline.item(atRow: 7))
        _ = try await settledOutline(in: first, rows: 10)
        try await waitUntil { model.scanCompleted && loader.scans == 2 }
        first.close()

        let second = await host(library, model: model, loader: loader, refreshToken: token)
        defer { second.close() }
        let remounted = try await settledOutline(in: second, rows: 10)
        #expect(Self.shape(of: remounted) == """
            ▾
              ·
              ▸
              ▾
                ▸
                ·
                ·
              ▾
                ·
                ·
            """)
        #expect(loader.scans == 2)
    }

    /// The Continue Reading section is a view of its own inside the `List`, so
    /// progress moving doesn't rebuild the tree. It has to stay a real section
    /// of the outline, appear when a suggestion does, and leave the tree alone.
    @Test func continueReadingIsASectionOfTheOutlineAndFollowsItsSuggestion() async throws {
        let tempRoot = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let library = try Library(in: tempRoot)
        let progress = ReadingProgressStore(defaults: InMemoryKeyValueStore(), storeKey: "rp-\(UUID())")

        let hosted = await host(library, continueReading: {
            progress.progress(forKey: "book", fileIdentityKey: nil).map { ("Book", $0.fraction) }
        })
        defer { hosted.close() }
        _ = try await settledOutline(in: hosted, rows: 8)

        progress.flushImmediately(forKey: "book", fileIdentityKey: nil, page: 1, total: 10, finished: false)

        let outline = try await settledOutline(in: hosted, rows: 10)
        #expect(Self.shape(of: outline) == """
            ▾
              ·
            ▾
              ·
              ▸
              ▾
                ▸
                ·
                ·
              ▸
            """)
    }

    /// Badges read the progress store in their own leaf view, not in the
    /// sidebar's body. They still have to appear when progress is written,
    /// on a nested row as well as a top-level one.
    @Test func badgesFollowProgressWithoutTheSidebarRendering() async throws {
        let tempRoot = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let library = try Library(in: tempRoot)
        let progress = ReadingProgressStore(defaults: InMemoryKeyValueStore(), storeKey: "rp-\(UUID())")
        let activeKey = library.activeBook.standardizedFileURL.path

        let hosted = await host(library, readingBadge: { url in
            progress.progress(forKey: url.standardizedFileURL.path, fileIdentityKey: nil).map {
                ReadingBadge.inProgress(fraction: $0.fraction)
            }
        })
        defer { hosted.close() }
        let outline = try await settledOutline(in: hosted, rows: 8)
        let bookRow = outline.convert(outline.rect(ofRow: 5), to: hosted.hostingView)
        let rowRect = hosted.hostingView.isFlipped
            ? bookRow
            : CGRect(x: bookRow.minX, y: hosted.size.height - bookRow.maxY, width: bookRow.width, height: bookRow.height)
        // The open book's row is accent-highlighted anyway, so count the
        // trailing edge only, where the badge goes.
        let trailing = CGRect(x: rowRect.maxX - 30, y: rowRect.minY, width: 30, height: rowRect.height)
        let before = try hosted.capture().accentPixels(in: trailing)

        progress.flushImmediately(forKey: activeKey, fileIdentityKey: nil, page: 4, total: 10, finished: false)

        try await hosted.settle("the badge to draw") {
            try hosted.capture().accentPixels(in: trailing) > before
        }
    }

    // MARK: - Helpers

    private final class CountingLiveLoader: LibraryTreeLoading, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var scans: Int { lock.withLock { count } }

        func loadTree(from url: URL, maxDepth: Int) async -> [FileNode] {
            lock.withLock { count += 1 }
            return await FileNode.loadTree(from: url, maxDepth: maxDepth)
        }
    }

    private func host(
        _ library: Library,
        model: LibrarySidebarModel? = nil,
        loader: any LibraryTreeLoading = LiveLibraryTreeLoader(),
        refreshToken: UUID = UUID(),
        readingBadge: @escaping (URL) -> ReadingBadge? = { _ in nil },
        continueReading: @escaping () -> (title: String, fraction: Double)? = { nil }
    ) async -> SnapshotRenderer.HostedView {
        await SnapshotRenderer.host(
            LibrarySidebar(
                model: model ?? LibrarySidebarModel(),
                rootURL: library.root,
                activeURL: library.activeBook,
                refreshToken: refreshToken,
                pinned: true,
                favorites: [],
                pageBookmarks: [],
                volumes: [],
                libraryTreeLoader: loader,
                currentPageIndex: { 0 },
                readingBadge: readingBadge,
                continueReading: continueReading,
                actions: LibrarySidebarActions()
            ),
            size: CGSize(width: 240, height: 720)
        )
    }

    /// The sidebar's outline once it shows `rows` rows. The tree loads in two
    /// async passes (shallow, then deep), so poll rather than guess a delay;
    /// on timeout, fail with the shape that did render. The timeout is
    /// generous (see `waitUntil`): 5 s ran out under a full parallel run.
    private func settledOutline(
        in hosted: SnapshotRenderer.HostedView,
        rows: Int,
        timeout: Duration = .seconds(20)
    ) async throws -> NSOutlineView {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            hosted.hostingView.layoutSubtreeIfNeeded()
            if let outline = hosted.firstSubview(of: NSOutlineView.self) {
                if outline.numberOfRows == rows { return outline }
                if clock.now >= deadline {
                    Issue.record("Expected \(rows) outline rows, got \(outline.numberOfRows):\n\(Self.shape(of: outline))")
                    throw SettleTimeout()
                }
            } else if clock.now >= deadline {
                Issue.record("The sidebar never rendered an outline")
                throw SettleTimeout()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private struct SettleTimeout: Error {}

    private static func shape(of outline: NSOutlineView) -> String {
        (0..<outline.numberOfRows).map { row in
            let item = outline.item(atRow: row)
            let marker = outline.isExpandable(item)
                ? (outline.isItemExpanded(item) ? "▾" : "▸")
                : "·"
            return String(repeating: "  ", count: outline.level(forRow: row)) + marker
        }
        .joined(separator: "\n")
    }
}
