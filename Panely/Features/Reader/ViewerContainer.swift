import AppKit
import SwiftUI

struct ViewerContainer: View {
    var images: [NSImage] = []
    var direction: ReadingDirection = .leftToRight
    var fitMode: FitMode = .fitScreen
    var identity: String = ""

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
                    identity: identity
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

private struct AppKitImageScroller: NSViewRepresentable {
    let images: [NSImage]
    let direction: ReadingDirection
    let fitMode: FitMode
    let identity: String

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

        let content = ImageStackView()
        content.onDoubleClick = { [weak scrollView] localPoint in
            guard let scrollView else { return }
            let coord = context.coordinator
            let isAtBase = abs(scrollView.magnification - coord.baseMagnification) < 0.01
            let target = isAtBase ? coord.baseMagnification * 2 : coord.baseMagnification
            scrollView.setMagnification(target, centeredAt: localPoint)
        }
        scrollView.documentView = content

        return scrollView
    }

    func updateNSView(_ scrollView: PanelyScrollView, context: Context) {
        guard let content = scrollView.documentView as? ImageStackView else { return }

        let ordered = direction.isRTL ? images.reversed() : images
        content.setImages(ordered)

        let resetNeeded = context.coordinator.lastIdentity != identity ||
                          context.coordinator.lastFitMode != fitMode
        context.coordinator.lastIdentity = identity
        context.coordinator.lastFitMode = fitMode

        DispatchQueue.main.async { [weak scrollView] in
            guard let scrollView else { return }
            applyFit(scrollView: scrollView, coordinator: context.coordinator, force: resetNeeded)
        }
    }

    private func applyFit(scrollView: NSScrollView, coordinator: Coordinator, force: Bool) {
        guard let content = scrollView.documentView else { return }
        let docSize = content.frame.size
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
        var baseMagnification: CGFloat = 1.0
    }
}

// MARK: - NSScrollView that forwards key events to SwiftUI

private final class PanelyScrollView: NSScrollView {
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

private final class ImageStackView: NSView {
    var onDoubleClick: ((NSPoint) -> Void)?

    private var imageViews: [NSImageView] = []
    private var currentImages: [NSImage] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func setImages(_ newImages: [NSImage]) {
        let sameCount = newImages.count == currentImages.count
        let sameIdentity = sameCount && zip(newImages, currentImages).allSatisfy { $0.0 === $0.1 }
        if sameIdentity { return }

        currentImages = newImages

        imageViews.forEach { $0.removeFromSuperview() }
        imageViews.removeAll()

        let totalWidth = currentImages.reduce(0) { $0 + $1.size.width }
        let maxHeight = currentImages.map { $0.size.height }.max() ?? 0

        setFrameSize(NSSize(width: totalWidth, height: maxHeight))

        var x: CGFloat = 0
        for image in currentImages {
            let y = (maxHeight - image.size.height) / 2
            let frame = NSRect(x: x, y: y, width: image.size.width, height: image.size.height)
            let iv = NSImageView(frame: frame)
            iv.image = image
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.imageFrameStyle = .none
            iv.wantsLayer = true
            iv.layer?.contentsGravity = .resizeAspect
            addSubview(iv)
            imageViews.append(iv)
            x += image.size.width
        }
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
