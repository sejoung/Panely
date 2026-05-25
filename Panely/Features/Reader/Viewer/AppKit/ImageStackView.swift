import AppKit

/// NSView that owns the page-frame layout and pooled NSImageViews powering
/// the reader. Horizontal (paged) mode eagerly materializes every page;
/// vertical (continuous / webtoon) mode lazily creates and recycles
/// NSImageViews as pages enter and leave the visible window so a 1000-page
/// strip never holds more than a few dozen live subviews.
final class ImageStackView: NSView {
    enum Axis { case horizontal, vertical }

    var onDoubleClick: ((NSPoint) -> Void)?

    private var currentImages: [NSImage] = []
    private(set) var axis: Axis = .horizontal

    /// Pre-computed frame for every page (always populated after setImages,
    /// even for pages that don't have a live NSImageView yet — used by
    /// frame(forPageAt:), pageIndex(forViewportY:), pageIndexRange(...)).
    private var pageFrames: [NSRect] = []

    /// Active NSImageViews keyed by page index. In horizontal (paged) mode
    /// every page has one (1–2 images, eager); in vertical (continuous)
    /// mode only pages whose frame intersects the visible window do.
    private var liveViews: [Int: NSImageView] = [:]

    /// Recycled NSImageView pool — refreshVisibleViews moves offscreen
    /// views here instead of releasing them, then pops one back when a
    /// new page comes into view. Avoids the alloc/dealloc churn of
    /// recreating views on every scroll tick.
    private var viewPool: [NSImageView] = []
    private static let viewPoolMaxSize = 24

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    @discardableResult
    func setImages(_ newImages: [NSImage], axis: Axis) -> Bool {
        let sameCount = newImages.count == currentImages.count
        let sameAxis = self.axis == axis
        let sameGeometry = sameCount && zip(newImages, currentImages).allSatisfy { newImage, currentImage in
            newImage.size == currentImage.size
        }

        // Fast path: count + axis + geometry unchanged → swap NSImage refs
        // in any live views (others pick up the new image when they come
        // into view). Per-page placeholder → real image swaps during lazy
        // load take this path when the header-derived dimensions match.
        if sameCount && sameAxis && sameGeometry {
            currentImages = newImages
            for (index, view) in liveViews where currentImages.indices.contains(index) {
                view.image = currentImages[index]
            }
            return false
        }

        // Slow path: structural change → recycle all live views, recompute
        // frames, and (for horizontal only) eagerly materialize every page.
        self.axis = axis
        currentImages = newImages

        for view in liveViews.values {
            view.removeFromSuperview()
            view.image = nil
            if viewPool.count < Self.viewPoolMaxSize {
                viewPool.append(view)
            }
        }
        liveViews.removeAll()

        switch axis {
        case .horizontal: layoutFramesHorizontally()
        case .vertical:   layoutFramesVertically()
        }

        // Horizontal mode is always paged (1–2 images): no benefit to
        // recycling, so materialize all views immediately.
        if axis == .horizontal {
            for index in pageFrames.indices {
                materializeViewForPage(index)
            }
        }
        // Vertical mode: views are created lazily by refreshVisibleViews
        // (called by AppKitImageScroller's bounds observer).
        return true
    }

    /// Materializes NSImageViews for pages whose frames intersect
    /// `visibleRect` (with a small look-ahead buffer above and below) and
    /// recycles any others. Vertical mode only — no-op for horizontal.
    func refreshVisibleViews(visibleRect: NSRect) {
        guard axis == .vertical, !pageFrames.isEmpty else { return }

        // Look-ahead buffer = one viewport in each direction so a fast
        // scroll doesn't reveal blank slots before recycling catches up.
        let bufferHeight = visibleRect.height
        let expandedRect = NSRect(
            x: visibleRect.minX,
            y: visibleRect.minY - bufferHeight,
            width: visibleRect.width,
            height: visibleRect.height + 2 * bufferHeight
        )

        var nowVisible: Set<Int> = []
        for (index, frame) in pageFrames.enumerated() where frame.intersects(expandedRect) {
            nowVisible.insert(index)
        }

        // Recycle views for pages no longer in the (buffered) visible window.
        for (index, view) in liveViews where !nowVisible.contains(index) {
            view.removeFromSuperview()
            view.image = nil
            if viewPool.count < Self.viewPoolMaxSize {
                viewPool.append(view)
            }
            liveViews.removeValue(forKey: index)
        }

        // Materialize views for newly-visible pages (reusing pool entries).
        for index in nowVisible where liveViews[index] == nil {
            materializeViewForPage(index)
        }
    }

    func frame(forPageAt index: Int) -> NSRect? {
        pageFrames.indices.contains(index) ? pageFrames[index] : nil
    }

    func pageIndex(forViewportY y: CGFloat) -> Int {
        guard !pageFrames.isEmpty else { return 0 }
        if y < pageFrames[0].minY { return 0 }
        for (i, frame) in pageFrames.enumerated() {
            if y >= frame.minY && y < frame.maxY {
                return i
            }
        }
        return pageFrames.count - 1
    }

    /// Half-open range of page indices whose frames intersect `rect`.
    /// Used by the viewer to ask the model to load every page currently
    /// visible (not just whichever one is at viewport center).
    func pageIndexRange(visibleIn rect: NSRect) -> Range<Int> {
        guard !pageFrames.isEmpty else { return 0..<0 }
        let topIndex = pageIndex(forViewportY: rect.minY)
        let bottomIndex = pageIndex(forViewportY: rect.maxY)
        let lower = max(0, min(topIndex, bottomIndex))
        let upper = min(pageFrames.count, max(topIndex, bottomIndex) + 1)
        return lower..<upper
    }

    private func layoutFramesHorizontally() {
        // Normalize pages to a shared display height (= tallest page's
        // native height), scaling width proportionally. Without this, a
        // spread that mixes pages of different native pixel sizes would
        // render each at its raw size, and the uniform scrollView
        // magnification can fit one page to the viewport but not the other.
        let targetHeight = currentImages.map { $0.size.height }.max() ?? 0

        let scaledSizes: [CGSize] = currentImages.map { image in
            guard image.size.height > 0 else { return image.size }
            let scale = targetHeight / image.size.height
            return CGSize(width: image.size.width * scale, height: targetHeight)
        }

        let totalWidth = scaledSizes.reduce(0) { $0 + $1.width }
        setFrameSize(NSSize(width: totalWidth, height: targetHeight))

        var frames: [NSRect] = []
        var x: CGFloat = 0
        for size in scaledSizes {
            frames.append(NSRect(x: x, y: 0, width: size.width, height: size.height))
            x += size.width
        }
        pageFrames = frames
    }

    private func layoutFramesVertically() {
        let maxWidth = currentImages.map { $0.size.width }.max() ?? 0
        let totalHeight = currentImages.reduce(0) { $0 + $1.size.height }
        setFrameSize(NSSize(width: maxWidth, height: totalHeight))

        var frames: [NSRect] = []
        var y: CGFloat = 0
        for image in currentImages {
            let x = (maxWidth - image.size.width) / 2
            frames.append(NSRect(x: x, y: y, width: image.size.width, height: image.size.height))
            y += image.size.height
        }
        pageFrames = frames
    }

    private func materializeViewForPage(_ index: Int) {
        guard pageFrames.indices.contains(index),
              currentImages.indices.contains(index) else { return }
        let frame = pageFrames[index]
        let image = currentImages[index]
        let view: NSImageView
        if let pooled = viewPool.popLast() {
            pooled.frame = frame
            pooled.image = image
            view = pooled
        } else {
            view = NSImageView(frame: frame)
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            view.imageFrameStyle = .none
            view.wantsLayer = true
            view.layer?.contentsGravity = .resizeAspect
        }
        addSubview(view)
        liveViews[index] = view
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let local = convert(event.locationInWindow, from: nil)
            onDoubleClick?(local)
            return
        }
        super.mouseDown(with: event)
    }
}
