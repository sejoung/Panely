import AppKit
import SwiftUI

struct ViewerContainer: View {
    var images: [NSImage] = []
    var direction: ReadingDirection = .leftToRight
    var fitMode: FitMode = .fitScreen
    var layout: PageLayout = .single
    var pageIndex: Int = 0
    var identity: String = ""
    var onPageIndexChanged: (Int) -> Void = { _ in }
    var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }
    var autoFitOnResize: Bool = true
    var viewerController: ViewerController? = nil

    var body: some View {
        ZStack {
            PanelyColor.bgPrimary
                .ignoresSafeArea()

            if images.isEmpty {
                emptyState
            } else {
                AppKitImageScroller(
                    images: images,
                    direction: direction,
                    fitMode: fitMode,
                    layout: layout,
                    pageIndex: pageIndex,
                    identity: identity,
                    onPageIndexChanged: onPageIndexChanged,
                    onVisibleRangeChanged: onVisibleRangeChanged,
                    autoFitOnResize: autoFitOnResize,
                    viewerController: viewerController
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: PanelySpacing.md) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(PanelyColor.textSecondary)
            Text("No image loaded")
                .font(PanelyTypography.body)
                .foregroundStyle(PanelyColor.textSecondary)
            Text("Open a folder, CBZ, or ZIP to start reading")
                .font(PanelyTypography.caption)
                .foregroundStyle(PanelyColor.textSecondary.opacity(0.7))
        }
    }
}

// MARK: - AppKit-backed scroller

struct AppKitImageScroller: NSViewRepresentable {
    let images: [NSImage]
    let direction: ReadingDirection
    let fitMode: FitMode
    let layout: PageLayout
    let pageIndex: Int
    let identity: String
    var onPageIndexChanged: (Int) -> Void = { _ in }
    var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }
    var autoFitOnResize: Bool = true
    var viewerController: ViewerController? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PanelyScrollView {
        let scrollView = PanelyScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 10.0
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.postsFrameChangedNotifications = true

        let content = ImageStackView()
        content.onDoubleClick = { [weak scrollView] localPoint in
            guard let scrollView else { return }
            let coord = context.coordinator
            let isAtBase = abs(scrollView.magnification - coord.baseMagnification) < 0.01
            let target = isAtBase ? coord.baseMagnification * 2 : coord.baseMagnification
            scrollView.setMagnification(target, centeredAt: localPoint)
        }
        scrollView.documentView = content

        context.coordinator.scrollView = scrollView
        context.coordinator.viewerController = viewerController
        viewerController?.attach(scrollView: scrollView)

        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator,
                      let sv = coordinator.scrollView,
                      coordinator.autoFitOnResize else { return }
                Self.applyFit(
                    scrollView: sv,
                    coordinator: coordinator,
                    fitMode: coordinator.lastFitMode,
                    force: false
                )
            }
        }

        scrollView.contentView.postsBoundsChangedNotifications = true
        let coordinator = context.coordinator
        coordinator.onPageIndexChanged = onPageIndexChanged
        coordinator.onVisibleRangeChanged = onVisibleRangeChanged
        // queue: nil → synchronous on the posting thread (always main here),
        // so currentPageIndex is always fresh when the user clicks a button.
        coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: nil
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator,
                      let sv = coordinator.scrollView,
                      coordinator.lastLayout.isContinuous,
                      let stack = sv.documentView as? ImageStackView else { return }
                let visibleRect = sv.documentVisibleRect

                // Page-index callback is suppressed during programmatic
                // scroll so the model doesn't feedback-loop.
                if !coordinator.isProgrammaticallyScrolling {
                    let centerY = visibleRect.midY
                    let visibleIndex = stack.pageIndex(forViewportY: centerY)
                    if visibleIndex != coordinator.lastPageIndex {
                        coordinator.lastPageIndex = visibleIndex
                        coordinator.onPageIndexChanged(visibleIndex)
                    }
                }

                // Visible-range callback always fires — required for lazy
                // loading to populate slots after auto-scroll to a restored
                // position or after large jumps.
                let visibleRange = stack.pageIndexRange(visibleIn: visibleRect)
                if visibleRange != coordinator.lastVisibleRange {
                    coordinator.lastVisibleRange = visibleRange
                    coordinator.onVisibleRangeChanged(visibleRange)
                }
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: PanelyScrollView, context: Context) {
        guard let content = scrollView.documentView as? ImageStackView else { return }

        // Keep the closure fresh — SwiftUI rebuilds props each tick, but the
        // observer only retains what we hand it at registration time.
        context.coordinator.onPageIndexChanged = onPageIndexChanged
        context.coordinator.onVisibleRangeChanged = onVisibleRangeChanged
        context.coordinator.autoFitOnResize = autoFitOnResize
        context.coordinator.viewerController = viewerController
        viewerController?.attach(scrollView: scrollView)

        let axis: ImageStackView.Axis = layout.isContinuous ? .vertical : .horizontal
        // RTL only applies to paged horizontal modes — webtoon strips are top-to-bottom.
        let ordered = (direction.isRTL && !layout.isContinuous) ? images.reversed() : images
        content.setImages(ordered, axis: axis)

        // resetNeeded drives setImages' identity check + applyFit's force.
        // We split the "should we force-reset magnification" decision so that
        // a layout-only change (e.g., single → vertical) preserves a user's
        // manual zoom; only identity (new book) or fitMode (user pressed
        // ⌘1/⌘2/⌘3) explicitly resets.
        let identityChanged = context.coordinator.lastIdentity != identity
        let fitModeChanged = context.coordinator.lastFitMode != fitMode
        let layoutChanged = context.coordinator.lastLayout != layout
        let resetNeeded = identityChanged || fitModeChanged || layoutChanged
        let forceFitReset = identityChanged || fitModeChanged
        context.coordinator.lastIdentity = identity
        context.coordinator.lastFitMode = fitMode
        context.coordinator.lastLayout = layout

        // Note: don't pre-set lastPageIndex here. We only mark a page as
        // "successfully shown" after the scroll actually lands (see below),
        // otherwise initial vertical renders that happen before the strip
        // has the target index in its stack would be silently dropped on
        // subsequent ticks (pageChanged would be false even though we never
        // scrolled).
        let pageChanged = context.coordinator.lastPageIndex != pageIndex

        // Apply fit synchronously so the user never sees a frame at the
        // previous magnification (which manifested as the image briefly
        // sliding/centering before snapping to fit-width on layout toggles).
        scrollView.layoutSubtreeIfNeeded()
        Self.applyFit(
            scrollView: scrollView,
            coordinator: context.coordinator,
            fitMode: fitMode,
            force: forceFitReset
        )

        if layout.isContinuous && pageChanged,
           let frame = content.frame(forPageAt: pageIndex) {
            // Suppress only the page-index callback during programmatic
            // scroll (avoids feedback). Visible-range callback is allowed to
            // fire so lazy loading kicks in for the newly-visible window —
            // critical when restoring a saved position into a strip that's
            // mostly placeholders.
            context.coordinator.isProgrammaticallyScrolling = true
            let currentX = scrollView.contentView.bounds.origin.x
            scrollView.contentView.scroll(to: NSPoint(x: currentX, y: frame.minY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            context.coordinator.isProgrammaticallyScrolling = false
            context.coordinator.lastPageIndex = pageIndex
        } else if !layout.isContinuous {
            // Paged mode never scrolls itself; just record the index.
            context.coordinator.lastPageIndex = pageIndex
        }
        // Vertical with no frame yet (stack still being populated): leave
        // lastPageIndex stale so the next updateNSView retries.

        // Ensure lazy loading kicks in for whatever's currently visible —
        // the bounds observer doesn't always fire on the first vertical
        // render (stack just installed, no actual scroll movement yet), so
        // we recompute and dispatch the range here too. Cheap when nothing
        // changed (range == lastVisibleRange short-circuits the callback).
        if layout.isContinuous {
            let visibleRect = scrollView.documentVisibleRect
            let range = content.pageIndexRange(visibleIn: visibleRect)
            if range != context.coordinator.lastVisibleRange {
                context.coordinator.lastVisibleRange = range
                onVisibleRangeChanged(range)
            }
        }
    }

    static func applyFit(
        scrollView: NSScrollView,
        coordinator: Coordinator,
        fitMode: FitMode,
        force: Bool
    ) {
        guard let content = scrollView.documentView else { return }
        // For vertical (continuous) strips, fitting against the entire stack
        // height collapses everything to a sliver. Use the first image as the
        // reference instead so fit-screen means "first page visible" and
        // fit-width means "first page fills viewport width".
        let docSize: CGSize
        if let stack = content as? ImageStackView,
           stack.axis == .vertical,
           let firstFrame = stack.frame(forPageAt: 0) {
            docSize = firstFrame.size
        } else {
            docSize = content.frame.size
        }
        // contentSize is the physical viewport (magnification-invariant); using
        // contentView.bounds.size here would feed back into itself because it
        // scales inversely with magnification, causing toggled fits to drift.
        let viewport = scrollView.contentSize
        guard docSize.width > 0, docSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return }

        let fit = FitCalculator.magnification(
            docSize: docSize,
            viewport: viewport,
            fitMode: fitMode
        )

        let userHasZoomed = abs(scrollView.magnification - coordinator.baseMagnification) > 0.001

        // Force (identity / fitMode change) always wins — those are explicit
        // user actions or fundamental content changes. Otherwise the lock
        // (autoFitOnResize=false) preserves the current magnification even
        // when the user hasn't manually zoomed yet — that's the whole point
        // of locking the view size.
        let shouldReset: Bool
        if force {
            shouldReset = true
        } else if !coordinator.autoFitOnResize {
            shouldReset = false
        } else {
            shouldReset = !userHasZoomed
        }

        if shouldReset {
            scrollView.magnification = fit
        }
        coordinator.baseMagnification = fit
        coordinator.viewerController?.baseMagnification = fit
    }

    @MainActor
    final class Coordinator {
        var lastIdentity: String = ""
        var lastFitMode: FitMode = .fitScreen
        var lastLayout: PageLayout = .single
        var lastPageIndex: Int = -1
        var lastVisibleRange: Range<Int> = 0..<0
        var baseMagnification: CGFloat = 1.0
        var isProgrammaticallyScrolling: Bool = false
        var autoFitOnResize: Bool = true
        weak var scrollView: NSScrollView?
        weak var viewerController: ViewerController?
        var frameObserver: NSObjectProtocol?
        var boundsObserver: NSObjectProtocol?
        var onPageIndexChanged: (Int) -> Void = { _ in }
        var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }

        deinit {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }
    }
}

// MARK: - NSScrollView that forwards key events to SwiftUI

final class PanelyScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }

    /// Sensitivity of cmd-scroll zoom. ~1% per scroll-delta unit feels right
    /// for both trackpad inertia and discrete mouse-wheel notches.
    static let zoomScrollSensitivity: CGFloat = 0.01

    static func zoomTarget(
        currentMagnification: CGFloat,
        scrollDelta: CGFloat,
        minMag: CGFloat,
        maxMag: CGFloat
    ) -> CGFloat {
        let factor = 1.0 + (scrollDelta * zoomScrollSensitivity)
        return min(max(currentMagnification * factor, minMag), maxMag)
    }

    override func scrollWheel(with event: NSEvent) {
        // ⌘ + scroll = zoom centered at the cursor (standard macOS gesture).
        if event.modifierFlags.contains(.command) && allowsMagnification {
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return }
            let target = Self.zoomTarget(
                currentMagnification: magnification,
                scrollDelta: delta,
                minMag: minMagnification,
                maxMag: maxMagnification
            )
            let center = convert(event.locationInWindow, from: nil)
            setMagnification(target, centeredAt: center)
            return
        }
        super.scrollWheel(with: event)
    }
}

// MARK: - Transparent top strip that forwards window drag / double-click-zoom

struct TitleBarPassthrough: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TitleBarPassthroughView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class TitleBarPassthroughView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [
            .cursorUpdate,
            .activeInKeyWindow,
            .inVisibleRect,
        ]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            switch action {
            case "Minimize":
                window?.performMiniaturize(nil)
            case "None":
                break
            default:
                window?.performZoom(nil)
            }
            return
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Clip view that centers the document when it's smaller than the viewport

final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }

        let docFrame = documentView.frame

        if rect.size.width > docFrame.size.width {
            rect.origin.x = docFrame.midX - rect.size.width / 2
        }
        if rect.size.height > docFrame.size.height {
            rect.origin.y = docFrame.midY - rect.size.height / 2
        }
        return rect
    }
}

// MARK: - Image stack NSView

final class ImageStackView: NSView {
    enum Axis { case horizontal, vertical }

    var onDoubleClick: ((NSPoint) -> Void)?

    private var imageViews: [NSImageView] = []
    private var currentImages: [NSImage] = []
    private(set) var axis: Axis = .horizontal

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func setImages(_ newImages: [NSImage], axis: Axis) {
        let sameCount = newImages.count == currentImages.count
        let sameAxis = self.axis == axis

        // Fast path: count + axis unchanged → swap NSImage references in
        // place. No subview tear-down, no relayout. Used during lazy loading
        // where placeholders are progressively replaced with real images.
        if sameCount && sameAxis {
            for i in 0..<newImages.count where currentImages[i] !== newImages[i] {
                if imageViews.indices.contains(i) {
                    imageViews[i].image = newImages[i]
                }
            }
            currentImages = newImages
            return
        }

        // Slow path: structural change → full relayout.
        self.axis = axis
        currentImages = newImages

        imageViews.forEach { $0.removeFromSuperview() }
        imageViews.removeAll()

        switch axis {
        case .horizontal: layoutHorizontally()
        case .vertical:   layoutVertically()
        }
    }

    func frame(forPageAt index: Int) -> NSRect? {
        guard imageViews.indices.contains(index) else { return nil }
        return imageViews[index].frame
    }

    func pageIndex(forViewportY y: CGFloat) -> Int {
        guard !imageViews.isEmpty else { return 0 }
        if y < imageViews[0].frame.minY { return 0 }
        for (i, iv) in imageViews.enumerated() {
            if y >= iv.frame.minY && y < iv.frame.maxY {
                return i
            }
        }
        return imageViews.count - 1
    }

    /// Half-open range of page indices whose frames intersect `rect`.
    /// Used by the viewer to ask the model to load every page currently
    /// visible (not just whichever one is at viewport center).
    func pageIndexRange(visibleIn rect: NSRect) -> Range<Int> {
        guard !imageViews.isEmpty else { return 0..<0 }
        let topIndex = pageIndex(forViewportY: rect.minY)
        let bottomIndex = pageIndex(forViewportY: rect.maxY)
        let lower = max(0, min(topIndex, bottomIndex))
        let upper = min(imageViews.count, max(topIndex, bottomIndex) + 1)
        return lower..<upper
    }

    private func layoutHorizontally() {
        let totalWidth = currentImages.reduce(0) { $0 + $1.size.width }
        let maxHeight = currentImages.map { $0.size.height }.max() ?? 0
        setFrameSize(NSSize(width: totalWidth, height: maxHeight))

        var x: CGFloat = 0
        for image in currentImages {
            let y = (maxHeight - image.size.height) / 2
            let frame = NSRect(x: x, y: y, width: image.size.width, height: image.size.height)
            addImageSubview(image: image, frame: frame)
            x += image.size.width
        }
    }

    private func layoutVertically() {
        let maxWidth = currentImages.map { $0.size.width }.max() ?? 0
        let totalHeight = currentImages.reduce(0) { $0 + $1.size.height }
        setFrameSize(NSSize(width: maxWidth, height: totalHeight))

        var y: CGFloat = 0
        for image in currentImages {
            let x = (maxWidth - image.size.width) / 2
            let frame = NSRect(x: x, y: y, width: image.size.width, height: image.size.height)
            addImageSubview(image: image, frame: frame)
            y += image.size.height
        }
    }

    private func addImageSubview(image: NSImage, frame: NSRect) {
        let iv = NSImageView(frame: frame)
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageFrameStyle = .none
        iv.wantsLayer = true
        iv.layer?.contentsGravity = .resizeAspect
        addSubview(iv)
        imageViews.append(iv)
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

#Preview {
    ViewerContainer()
        .frame(width: 800, height: 600)
}
