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
                    onPageIndexChanged: onPageIndexChanged
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
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator, let sv = coordinator.scrollView else { return }
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
                      !coordinator.isProgrammaticallyScrolling,
                      let stack = sv.documentView as? ImageStackView else { return }
                let visibleRect = sv.documentVisibleRect
                let centerY = visibleRect.midY
                let visibleIndex = stack.pageIndex(forViewportY: centerY)
                guard visibleIndex != coordinator.lastPageIndex else { return }
                coordinator.lastPageIndex = visibleIndex
                coordinator.onPageIndexChanged(visibleIndex)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: PanelyScrollView, context: Context) {
        guard let content = scrollView.documentView as? ImageStackView else { return }

        // Keep the closure fresh — SwiftUI rebuilds props each tick, but the
        // observer only retains what we hand it at registration time.
        context.coordinator.onPageIndexChanged = onPageIndexChanged

        let axis: ImageStackView.Axis = layout.isContinuous ? .vertical : .horizontal
        // RTL only applies to paged horizontal modes — webtoon strips are top-to-bottom.
        let ordered = (direction.isRTL && !layout.isContinuous) ? images.reversed() : images
        content.setImages(ordered, axis: axis)

        let resetNeeded = context.coordinator.lastIdentity != identity ||
                          context.coordinator.lastFitMode != fitMode ||
                          context.coordinator.lastLayout != layout
        context.coordinator.lastIdentity = identity
        context.coordinator.lastFitMode = fitMode
        context.coordinator.lastLayout = layout

        let pageChanged = context.coordinator.lastPageIndex != pageIndex
        context.coordinator.lastPageIndex = pageIndex

        // Apply fit synchronously so the user never sees a frame at the
        // previous magnification (which manifested as the image briefly
        // sliding/centering before snapping to fit-width on layout toggles).
        scrollView.layoutSubtreeIfNeeded()
        Self.applyFit(
            scrollView: scrollView,
            coordinator: context.coordinator,
            fitMode: fitMode,
            force: resetNeeded
        )

        if layout.isContinuous && pageChanged,
           let frame = content.frame(forPageAt: pageIndex) {
            // Suppress the bounds observer for the duration of this scroll so
            // it doesn't fire back into the model with the in-flight position.
            context.coordinator.isProgrammaticallyScrolling = true
            // Preserve horizontal pan when the user has zoomed in past fit-width.
            let currentX = scrollView.contentView.bounds.origin.x
            scrollView.contentView.scroll(to: NSPoint(x: currentX, y: frame.minY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            context.coordinator.isProgrammaticallyScrolling = false
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
        if force || !userHasZoomed {
            scrollView.magnification = fit
        }
        coordinator.baseMagnification = fit
    }

    @MainActor
    final class Coordinator {
        var lastIdentity: String = ""
        var lastFitMode: FitMode = .fitScreen
        var lastLayout: PageLayout = .single
        var lastPageIndex: Int = -1
        var baseMagnification: CGFloat = 1.0
        var isProgrammaticallyScrolling: Bool = false
        weak var scrollView: NSScrollView?
        var frameObserver: NSObjectProtocol?
        var boundsObserver: NSObjectProtocol?
        var onPageIndexChanged: (Int) -> Void = { _ in }

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
        let sameIdentity = sameCount && zip(newImages, currentImages).allSatisfy { $0.0 === $0.1 }
        if sameIdentity && sameAxis { return }

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
