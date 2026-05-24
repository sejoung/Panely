import AppKit
import Foundation
@testable import Panely

/// On-disk fixture for snapshots that need a populated LibrarySidebar.
/// Builds a small but realistic series tree in a temp dir; cleans up on
/// `deinit` so each suite leaves the system tidy. Holding it on a property
/// keeps the directory alive for the scope of the test that needs it.
@MainActor
final class LibraryFixture {
    /// Library root URL passed into `explicitLibraryRootURL`. The sidebar
    /// header shows this URL's `lastPathComponent`, so the directory is
    /// named "Sample Library" rather than the auto-generated paneltest UUID
    /// to keep the screenshot's sidebar title pretty.
    let root: URL
    /// A book living inside the fixture — convenient for setting
    /// `currentSourceURL` to a path the sidebar will actually highlight.
    let activeBook: URL

    /// Underlying temp dir that the fixture lives inside. Held only for
    /// cleanup on `deinit`; not exposed because callers should reference
    /// `root` (the pretty-named child) for everything.
    private let tempRoot: URL

    init() throws {
        tempRoot = try Fixture.makeTempDir()
        root = tempRoot.appendingPathComponent("Sample Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let seriesA = root.appendingPathComponent("Series A", isDirectory: true)
        let seriesB = root.appendingPathComponent("Series B", isDirectory: true)
        let oneshots = root.appendingPathComponent("One-shots", isDirectory: true)
        for dir in [seriesA, seriesB, oneshots] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Marker files — empty bytes, real `.cbz` extension so the sidebar
        // surfaces them with the archive icon and badge.
        for name in ["Volume 01.cbz", "Volume 02.cbz", "Volume 03.cbz"] {
            _ = try Fixture.writeFile(seriesA.appendingPathComponent(name))
        }
        for name in ["Volume 01.cbz", "Volume 02.cbz"] {
            _ = try Fixture.writeFile(seriesB.appendingPathComponent(name))
        }
        for name in ["Mysterious Tales.cbz", "Sketch Diary.cbz"] {
            _ = try Fixture.writeFile(oneshots.appendingPathComponent(name))
        }

        activeBook = seriesA.appendingPathComponent("Volume 01.cbz")
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }
}

/// Programmatic sample comic pages + pre-configured viewmodels for the
/// snapshot gallery. Everything here is locally drawn — no external
/// content is loaded — so the gallery has zero copyright exposure.
@MainActor
enum SnapshotSampleContent {
    /// Default portrait page size. Mirrors a typical scanned manga page
    /// aspect (~2:3) so layout previews look natural.
    nonisolated static let pageSize = CGSize(width: 800, height: 1200)

    // MARK: - Placeholder pages

    /// A coloured placeholder page with a large "Page N" label centred and
    /// a footer reading `n / total`. Deterministic — same inputs always
    /// produce the same pixels so snapshots are reproducible.
    static func makeSamplePage(number: Int, of total: Int, size: CGSize = pageSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let hue = CGFloat((number - 1) % max(total, 1)) / CGFloat(max(total, 1))
        let background = NSColor(hue: hue, saturation: 0.18, brightness: 0.94, alpha: 1)
        background.setFill()
        NSRect(origin: .zero, size: size).fill()

        // Subtle gridded margin so the page looks like a designed sample
        // rather than a flat fill — helps the manual look intentional.
        NSColor.black.withAlphaComponent(0.06).setStroke()
        let margin: CGFloat = 24
        let frame = NSBezierPath(rect: NSRect(x: margin, y: margin,
                                              width: size.width - 2 * margin,
                                              height: size.height - 2 * margin))
        frame.lineWidth = 1
        frame.stroke()

        let title = "Page \(number)"
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 96, weight: .black),
            .foregroundColor: NSColor.black.withAlphaComponent(0.78),
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttrs)
        let titleRect = NSRect(
            x: (size.width - titleSize.width) / 2,
            y: (size.height - titleSize.height) / 2,
            width: titleSize.width,
            height: titleSize.height
        )
        (title as NSString).draw(in: titleRect, withAttributes: titleAttrs)

        let footer = "\(number) / \(total)"
        let footerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .medium),
            .foregroundColor: NSColor.black.withAlphaComponent(0.45),
        ]
        let footerSize = (footer as NSString).size(withAttributes: footerAttrs)
        (footer as NSString).draw(
            at: NSPoint(x: (size.width - footerSize.width) / 2, y: 60),
            withAttributes: footerAttrs
        )

        return image
    }

    static func makeSampleStrip(count: Int) -> [NSImage] {
        (1...count).map { makeSamplePage(number: $0, of: count) }
    }

    // MARK: - Mock ComicSource

    static func mockSource(pageCount: Int, title: String = "Sample Volume 1") -> ComicSource {
        let pages = (0..<pageCount).map { i in
            ComicPage(
                source: .file(URL(fileURLWithPath: "/sample/page-\(i + 1).png")),
                displayName: "page-\(i + 1)"
            )
        }
        return ComicSource(title: title, pages: pages)
    }

    // MARK: - Pre-configured viewmodels

    private static func snapshotViewModel() -> ReaderViewModel {
        let vm = makeTestViewModel()
        vm.favorites.favorites = []
        vm.pageBookmarks.pageBookmarksByBook = [:]
        return vm
    }

    /// Empty state — nothing loaded, default chrome.
    static func emptyViewModel() -> ReaderViewModel {
        snapshotViewModel()
    }

    /// Loaded book at the requested page index + layout. Drives the
    /// "main reader" and "layout variation" shots. When `library` is
    /// provided, the viewmodel points at a real on-disk book and the
    /// sidebar's FileNode scan returns the populated fixture tree.
    static func loadedViewModel(
        layout: PageLayout = .single,
        fitMode: FitMode = .fitScreen,
        direction: ReadingDirection = .leftToRight,
        sidebarPinned: Bool = false,
        toolbarPinned: Bool = true,
        thumbnailSidebarVisible: Bool = false,
        pageIndex: Int = 0,
        pageCount: Int = 24,
        library: LibraryFixture? = nil
    ) -> ReaderViewModel {
        let vm = snapshotViewModel()
        vm.preferences.layout = layout
        vm.preferences.fitMode = fitMode
        vm.preferences.direction = direction
        vm.preferences.sidebarMode.pinned = sidebarPinned
        vm.preferences.toolbarPinned = toolbarPinned
        vm.preferences.thumbnailSidebarVisible = thumbnailSidebarVisible

        vm.source = mockSource(pageCount: pageCount)
        if let library {
            vm.explicitLibraryRootURL = library.root
            vm.currentSourceURL = library.activeBook
            vm.openedSourceURL = library.activeBook
            // Real sibling volumes from the fixture so volume counter
            // ("Vol 1 / 3") renders correctly.
            vm.siblings = (1...3).map {
                library.root
                    .appendingPathComponent("Series A", isDirectory: true)
                    .appendingPathComponent("Volume 0\($0).cbz")
            }
        } else {
            vm.currentSourceURL = URL(fileURLWithPath: "/sample/Volume-01.cbz")
            vm.openedSourceURL = vm.currentSourceURL
            vm.siblings = (1...3).map { URL(fileURLWithPath: "/sample/Volume-0\($0).cbz") }
        }
        vm.currentPageIndex = pageIndex
        vm.imageLoader.currentImages = makeSampleStrip(count: layout.isContinuous ? min(pageCount, 6) : (layout == .double ? 2 : 1))
        return vm
    }

    /// End-of-volume scenario — last page reached with a next sibling
    /// available so the card auto-appears.
    static func atLastPageViewModel() -> ReaderViewModel {
        let total = 24
        let vm = loadedViewModel(
            sidebarPinned: false,
            pageIndex: total - 1,
            pageCount: total
        )
        return vm
    }

    /// Previous-volume card state — at page 0 with a prior sibling AND the
    /// intent cue armed (the user pressed back once already).
    static func atFirstPageWithPrevCueViewModel() -> ReaderViewModel {
        let vm = loadedViewModel(pageIndex: 0)
        // Position on the second sibling so "previous" is meaningful.
        vm.currentSourceURL = URL(fileURLWithPath: "/sample/Volume-02.cbz")
        vm.openedSourceURL = vm.currentSourceURL
        vm.wantsPreviousVolumePrompt = true
        return vm
    }

    /// Sidebar populated with all four sections (Volumes excluded — that's
    /// zip-in-zip only) for the "library pinned" hero shot. Caller owns the
    /// `LibraryFixture` lifetime so its temp dir survives the snapshot.
    static func sidebarPopulatedViewModel(library: LibraryFixture) -> ReaderViewModel {
        let vm = loadedViewModel(sidebarPinned: true, pageIndex: 6, library: library)
        // Inject favorites + page bookmarks directly into the stores so the
        // sidebar surfaces the Favorites + Bookmarks sections in addition
        // to the Files tree from the fixture.
        if let data = try? library.activeBook.bookmarkData() {
            vm.favorites.favorites.append(
                FavoriteBook(
                    id: UUID(),
                    path: library.activeBook.path,
                    title: "Series A · Volume 01",
                    addedAt: Date(),
                    bookmarkData: data,
                    isDirectory: false
                )
            )
        }
        let key = vm.positionKey(for: library.activeBook)
        vm.pageBookmarks.pageBookmarksByBook[key] = [
            PageBookmark(pageIndex: 3),
            PageBookmark(pageIndex: 8),
            PageBookmark(pageIndex: 15),
        ]
        return vm
    }

    /// Loading-overlay state — `isLoading=true` plus a stage-aware message.
    static func loadingViewModel(message: String = "Extracting archive…") -> ReaderViewModel {
        let vm = snapshotViewModel()
        vm.isLoading = true
        vm.loadingMessage = message
        return vm
    }
}
