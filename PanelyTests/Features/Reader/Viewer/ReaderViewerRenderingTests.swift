import AppKit
import SwiftUI
import Testing
@testable import Panely

/// Hosts the real reader viewer (`ViewerContainer` → `AppKitImageScroller` →
/// `ImageStackView`) in an off-screen window and checks where each page
/// actually lands on screen — which image view shows which page, in what
/// order, at what size. The spread / layout models can all be right while
/// the viewer still draws pages swapped, overlapping, unfitted or scrolled
/// to the wrong slot; only the built AppKit hierarchy shows that.
@MainActor
struct ReaderViewerRenderingTests {
    private static let window = CGSize(width: 800, height: 600)
    /// Points of slack for fractional magnification.
    private static let tolerance: CGFloat = 1

    // MARK: - Paged layouts

    @Test func singlePageIsFittedAndCentred() async throws {
        let page = NSImage(size: NSSize(width: 600, height: 900))
        let rendered = try await render(images: [page], layout: .single, expectedViews: 1)
        defer { rendered.close() }

        let rect = try rendered.rect(of: page)
        // fit-screen: 600×900 into 800×600 → 400×600, centred.
        Self.expectClose(rect, NSRect(x: 200, y: 0, width: 400, height: 600))
    }

    @Test func doubleSpreadLeftToRightPlacesFirstPageOnTheLeft() async throws {
        let first = NSImage(size: NSSize(width: 600, height: 900))
        let second = NSImage(size: NSSize(width: 500, height: 1000))
        let rendered = try await render(images: [first, second], layout: .double, expectedViews: 2)
        defer { rendered.close() }

        try Self.expectSpread(rendered, leftToRight: [first, second])
    }

    @Test func doubleSpreadRightToLeftPlacesFirstPageOnTheRight() async throws {
        let first = NSImage(size: NSSize(width: 600, height: 900))
        let second = NSImage(size: NSSize(width: 500, height: 1000))
        let rendered = try await render(
            images: [first, second],
            direction: .rightToLeft,
            layout: .double,
            expectedViews: 2
        )
        defer { rendered.close() }

        try Self.expectSpread(rendered, leftToRight: [second, first])
    }

    /// Double-page with the standalone cover, driven through the view model
    /// as the reader does: the cover shows alone and centred, the next
    /// spread pairs pages 2–3, and in right-to-left reading page 2 sits on
    /// the right.
    @Test func coverAloneSpreadsRenderThroughTheViewModel() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Distinct widths identify each decoded page on screen.
        let widths = [300, 310, 320, 330]
        let pages: [ComicPage] = try widths.enumerated().map { i, width in
            let url = root.appendingPathComponent("\(i).png")
            try Fixture.makePNG(width: width, height: 450).write(to: url)
            return ComicPage(source: .file(url), displayName: "\(i).png")
        }
        let vm = makeTestViewModel()
        vm.source = ComicSource(title: "Cover", pages: pages)
        vm.layout = .double
        vm.doublePageCoverAlone = true
        vm.direction = .rightToLeft
        await vm.refreshImages()

        let hosted = await SnapshotRenderer.host(ViewModelViewer(viewModel: vm), size: Self.window)
        defer { hosted.close() }

        let cover = try await settledRects(in: hosted, count: 1)
        #expect(cover.map(\.width) == [300])
        Self.expectClose(cover[0].rect.midX, Self.window.width / 2)

        vm.next()
        await vm.pagedRefreshTask?.value
        let spread = try await settledRects(in: hosted, count: 2)
        // Sorted left → right on screen: page 3 (320 wide), then page 2 (310).
        #expect(spread.map(\.width) == [320, 310])
        Self.expectClose(spread[0].rect.maxX, spread[1].rect.minX)
    }

    // MARK: - Vertical strip

    /// The strip runs top to bottom in page order whatever the reading
    /// direction, each page directly below the last, centred horizontally,
    /// and the first page fitted to the window.
    @Test func verticalStripStacksPagesInOrderIgnoringRightToLeft() async throws {
        let images = [600, 300, 600, 450, 600].map { NSImage(size: NSSize(width: $0, height: 900)) }
        let rendered = try await render(
            images: images,
            direction: .rightToLeft,
            layout: .vertical,
            expectedViews: 1
        )
        defer { rendered.close() }

        let stack = rendered.stack
        let frames = try (0..<images.count).map { try #require(stack.frame(forPageAt: $0)) }
        for i in frames.indices {
            Self.expectClose(frames[i].midX, stack.bounds.midX)
            #expect(frames[i].size == images[i].size)
            if i > 0 { Self.expectClose(frames[i].minY, frames[i - 1].maxY) }
        }
        // Every live view shows the page its slot belongs to.
        for view in rendered.imageViews {
            let index = try #require(images.firstIndex { $0 === view.image })
            #expect(view.frame == frames[index], "page \(index) drawn in another page's slot")
        }
        // Scrolled to the top, page 0 fills the window: 600×900 fitted → 400×600.
        let first = try rendered.rect(of: images[0])
        Self.expectClose(first, NSRect(x: 200, y: 0, width: 400, height: 600))
    }

    /// Opening a strip on a restored page scrolls that page's top to the top
    /// of the window.
    @Test func verticalStripOpensScrolledToTheRestoredPage() async throws {
        let images = (0..<6).map { NSImage(size: NSSize(width: 600 - $0 * 10, height: 900)) }
        let rendered = try await render(images: images, layout: .vertical, pageIndex: 3, expectedViews: 1)
        defer { rendered.close() }

        try await waitUntil { rendered.view(showing: images[3]) != nil }
        let restored = try rendered.rect(of: images[3])
        // Window coordinates are bottom-up: the page's top edge is the window's.
        Self.expectClose(restored.maxY, Self.window.height)
        Self.expectClose(restored.midX, Self.window.width / 2)
    }

    // MARK: - Hosting

    /// Mounts the viewer the way a book open does — scroller first (a source
    /// is set, no pages decoded yet), pages once they arrive — then waits
    /// until `expectedViews` image views are live.
    private func render(
        images: [NSImage],
        direction: ReadingDirection = .leftToRight,
        layout: PageLayout,
        pageIndex: Int = 0,
        expectedViews: Int
    ) async throws -> Rendered {
        let props = ViewerProps(direction: direction, layout: layout, pageIndex: pageIndex)
        let hosted = await SnapshotRenderer.host(PropsViewer(props: props), size: Self.window)
        do {
            try await waitUntil {
                (hosted.firstSubview(of: PanelyScrollView.self)?.frame.width ?? 0) > 0
            }
            props.images = images
            try await waitUntil {
                guard let stack = hosted.firstSubview(of: ImageStackView.self) else { return false }
                return Rendered.imageViews(in: stack).count >= expectedViews
            }
            let stack = try #require(hosted.firstSubview(of: ImageStackView.self))
            return Rendered(hosted: hosted, stack: stack)
        } catch {
            hosted.close()
            throw error
        }
    }

    /// Image views in `hosted`'s stack, as (page width, window rect), sorted
    /// left to right — polled until exactly `count` are live and laid out.
    private func settledRects(in hosted: SnapshotRenderer.HostedView, count: Int) async throws -> [(width: Int, rect: NSRect)] {
        func current() -> [(width: Int, rect: NSRect)]? {
            guard let stack = hosted.firstSubview(of: ImageStackView.self) else { return nil }
            let views = Rendered.imageViews(in: stack)
            guard views.count == count else { return nil }
            return views
                .compactMap { view in
                    // Decoded pages only — not a placeholder still on screen.
                    guard let image = view.image,
                          image.representations.contains(where: { $0.pixelsWide > 0 }) else { return nil }
                    return (Int(image.size.width), view.convert(view.bounds, to: nil))
                }
                .sorted { $0.1.minX < $1.1.minX }
        }
        try await waitUntil { current()?.count == count }
        return try #require(current())
    }

    @MainActor
    private struct Rendered {
        let hosted: SnapshotRenderer.HostedView
        let stack: ImageStackView

        var imageViews: [NSImageView] { Self.imageViews(in: stack) }

        static func imageViews(in stack: ImageStackView) -> [NSImageView] {
            stack.subviews.compactMap { $0 as? NSImageView }
        }

        func view(showing image: NSImage) -> NSImageView? {
            imageViews.first { $0.image === image }
        }

        /// Where `image` is drawn, in window coordinates (bottom-left origin).
        func rect(of image: NSImage) throws -> NSRect {
            let imageView = try #require(self.view(showing: image), "no image view shows this page")
            return imageView.convert(imageView.bounds, to: nil)
        }

        func close() { hosted.close() }
    }

    /// `leftToRight` is the on-screen order. Pages share one height, abut
    /// without overlap, keep their aspect ratios, and the spread as a whole
    /// is fitted and centred in the window.
    private static func expectSpread(_ rendered: Rendered, leftToRight: [NSImage]) throws {
        let rects = try leftToRight.map { try rendered.rect(of: $0) }
        for (image, rect) in zip(leftToRight, rects) {
            expectClose(rect.width / rect.height, image.size.width / image.size.height, tolerance: 0.01)
        }
        for i in 1..<rects.count {
            #expect(rects[i - 1].minX < rects[i].minX, "pages out of order")
            expectClose(rects[i].minX, rects[i - 1].maxX)
            expectClose(rects[i].height, rects[0].height)
            expectClose(rects[i].minY, rects[0].minY)
        }
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let bounds = NSRect(origin: .zero, size: window)
        #expect(bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(union), "spread overflows the window: \(union)")
        #expect(abs(union.width - window.width) < tolerance || abs(union.height - window.height) < tolerance,
                "spread not fitted: \(union)")
        expectClose(union.midX, window.width / 2)
        expectClose(union.midY, window.height / 2)
    }

    private static func expectClose(
        _ actual: CGFloat,
        _ expected: CGFloat,
        tolerance: CGFloat = Self.tolerance,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual - expected) <= tolerance, "\(actual) ≉ \(expected)", sourceLocation: sourceLocation)
    }

    private static func expectClose(_ actual: NSRect, _ expected: NSRect, sourceLocation: SourceLocation = #_sourceLocation) {
        let close = abs(actual.minX - expected.minX) <= tolerance
            && abs(actual.minY - expected.minY) <= tolerance
            && abs(actual.width - expected.width) <= tolerance
            && abs(actual.height - expected.height) <= tolerance
        #expect(close, "\(actual) ≉ \(expected)", sourceLocation: sourceLocation)
    }
}

/// Viewer inputs a test changes after mounting.
@MainActor
@Observable
private final class ViewerProps {
    var images: [NSImage] = []
    let direction: ReadingDirection
    let layout: PageLayout
    let pageIndex: Int

    init(direction: ReadingDirection, layout: PageLayout, pageIndex: Int) {
        self.direction = direction
        self.layout = layout
        self.pageIndex = pageIndex
    }
}

private struct PropsViewer: View {
    let props: ViewerProps

    var body: some View {
        ViewerContainer(
            images: props.images,
            direction: props.direction,
            fitMode: .fitScreen,
            layout: props.layout,
            pageIndex: props.pageIndex,
            hasSource: true,
            identity: "book"
        )
    }
}

/// The viewer fed straight from a view model, as `ViewerArea` does (minus
/// the chrome overlays), so model changes re-render it.
private struct ViewModelViewer: View {
    let viewModel: ReaderViewModel

    var body: some View {
        ViewerContainer(
            images: viewModel.currentImages,
            direction: viewModel.effectiveDirection,
            fitMode: .fitScreen,
            layout: viewModel.layout,
            pageIndex: viewModel.currentPageIndex,
            hasSource: viewModel.hasSource,
            identity: "book"
        )
    }
}
