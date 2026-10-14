import AppKit
import QuartzCore
import SwiftUI

/// Draws one page's translations over the original and makes each balloon
/// clickable: a click opens the original next to its translation.
///
/// Hosted by `ImageStackView` above all page images (not inside the page's
/// image view), positioned over the page and extended past it when a balloon
/// crosses into the next slice of a strip. `pageOrigin`/`scale` map page
/// pixels into this view.
///
/// Balloons still waiting for their translation show as a softly pulsing
/// outline with "…", so progress is visible right on the page.
///
/// Only balloons take part in hit testing — everywhere else the overlay is
/// transparent to the mouse, so scrolling, panning and double-click zoom work
/// exactly as without it. When the overlay is switched off (⇧⌘T) nothing is
/// drawn, but balloons still highlight on hover and open on click.
final class TranslationOverlayView: NSView {
    private(set) var page: TranslatedPage?
    private(set) var showsTranslation = false
    private var pageOrigin: CGPoint = .zero
    private var scale: CGFloat = 1

    private var hoveredBubbleID: Int?
    private var popover: NSPopover?
    private var pendingPopover: Task<Void, Never>?
    private var trackingArea: NSTrackingArea?
    private let pendingView = PendingBubblesView()
    /// Fitted text per balloon, valid for `fittedForScale`. Fitting is a small
    /// binary search per balloon; redraws (hover, scroll) reuse it.
    private var fittedText: [Int: (text: String, string: NSAttributedString, size: CGSize)] = [:]
    private var fittedForScale: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        pendingView.frame = bounds
        pendingView.autoresizingMask = [.width, .height]
        addSubview(pendingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameters:
    ///   - pageOrigin: where page pixel (0, 0) sits in this view.
    ///   - scale: view points per page pixel.
    func update(page: TranslatedPage?, showsTranslation: Bool, pageOrigin: CGPoint, scale: CGFloat) {
        let geometryChanged = pageOrigin != self.pageOrigin || scale != self.scale
        guard page != self.page || showsTranslation != self.showsTranslation || geometryChanged else { return }
        if page?.bubbles.map(\.id) != self.page?.bubbles.map(\.id) {
            hoveredBubbleID = nil
        }
        if page == nil { closePopover() }
        self.page = page
        self.showsTranslation = showsTranslation
        self.pageOrigin = pageOrigin
        self.scale = scale
        pendingView.update(rects: pendingRects(), glyph: pendingGlyph())
        needsDisplay = true
    }

    // MARK: - Geometry

    private func patchInView(_ bubble: TranslatedBubble) -> CGRect {
        guard let page else { return .zero }
        let rect = TranslationOverlayLayout.patchRect(for: bubble, imageSize: page.imageSize)
        return CGRect(
            x: pageOrigin.x + rect.minX * scale,
            y: pageOrigin.y + rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    private func bubble(at point: NSPoint) -> TranslatedBubble? {
        page?.bubbles.first { patchInView($0).contains(point) }
    }

    private func pendingRects() -> [CGRect] {
        guard let page else { return [] }
        return page.bubbles.filter { $0.translation == nil }.map(patchInView)
    }

    private func pendingGlyph() -> CGFloat {
        guard let glyph = page?.bubbles.first(where: { $0.translation == nil })?.glyphSize else { return 12 }
        return CGFloat(glyph) * scale
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        return bubble(at: convert(point, from: superview)) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(bubble(at: convert(event.locationInWindow, from: nil))?.id)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    override func mouseDown(with event: NSEvent) {
        // A double-click is the viewer's zoom gesture — hand it on to
        // `ImageStackView` and drop the pending popover.
        if event.clickCount >= 2 {
            pendingPopover?.cancel()
            superview?.mouseDown(with: event)
            return
        }
        guard let bubble = bubble(at: convert(event.locationInWindow, from: nil)) else {
            superview?.mouseDown(with: event)
            return
        }
        // Wait out the double-click interval so a zoom double-click on a
        // balloon doesn't flash a popover first.
        pendingPopover?.cancel()
        let bubbleID = bubble.id
        pendingPopover = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled else { return }
            self?.showPopover(forBubbleID: bubbleID)
        }
    }

    private func setHovered(_ id: Int?) {
        guard id != hoveredBubbleID else { return }
        hoveredBubbleID = id
        (id == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        needsDisplay = true
    }

    // MARK: - Popover

    private func showPopover(forBubbleID id: Int) {
        // Look the balloon up again: its translation may have arrived meanwhile.
        guard let bubble = page?.bubbles.first(where: { $0.id == id }) else { return }
        closePopover()
        let host = NSHostingController(
            rootView: TranslationBubblePopover(
                source: bubble.source,
                translation: bubble.translation,
                alternates: bubble.alternates ?? [:]
            )
        )
        host.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.contentViewController = host
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        let anchor = patchInView(bubble).intersection(bounds)
        guard !anchor.isNull, !anchor.isEmpty else { return }
        popover.show(relativeTo: anchor, of: self, preferredEdge: bubble.isVertical ? .maxX : .maxY)
        self.popover = popover
    }

    private func closePopover() {
        pendingPopover?.cancel()
        pendingPopover = nil
        popover?.close()
        popover = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { closePopover() }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let page else { return }
        if fittedForScale != scale {
            fittedText = [:]
            fittedForScale = scale
        }
        for bubble in page.bubbles {
            let patch = patchInView(bubble)
            guard patch.intersects(dirtyRect) else { continue }
            if showsTranslation, let translation = bubble.translation, !translation.isEmpty {
                drawTranslation(translation, of: bubble, in: patch)
            }
            if bubble.id == hoveredBubbleID {
                drawHoverHighlight(around: patch, glyph: CGFloat(bubble.glyphSize) * scale)
            }
        }
    }

    private func drawTranslation(_ translation: String, of bubble: TranslatedBubble, in patch: CGRect) {
        let glyph = CGFloat(bubble.glyphSize) * scale
        let background = bubble.background
        let fill = NSColor(srgbRed: background.red, green: background.green, blue: background.blue, alpha: 1)
        let path = NSBezierPath(roundedRect: patch, xRadius: max(4, glyph * 0.5), yRadius: max(4, glyph * 0.5))

        if background.isUniform {
            // A balloon or caption box: a solid patch in its own tone is invisible.
            fill.setFill()
            path.fill()
        } else {
            // Over artwork a hard box looks pasted on — feather its edge into
            // the drawing instead.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = fill
            shadow.shadowBlurRadius = max(6, glyph * 0.8)
            shadow.shadowOffset = .zero
            shadow.set()
            fill.withAlphaComponent(0.92).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let inner = patch.insetBy(dx: glyph * 0.3, dy: glyph * 0.3)
        guard inner.width > 4, inner.height > 4 else { return }
        let text: (string: NSAttributedString, size: CGSize)
        if let cached = fittedText[bubble.id], cached.text == translation {
            text = (cached.string, cached.size)
        } else {
            let fitted = TranslationOverlayLayout.fittedText(
                translation,
                in: inner.size,
                maxFontSize: max(glyph * 0.95, 8),
                color: background.isDark ? .white : .black,
                outline: background.isUniform ? nil : (background.isDark ? .black : .white)
            )
            fittedText[bubble.id] = (translation, fitted.string, fitted.size)
            text = fitted
        }
        let textRect = CGRect(
            x: inner.minX,
            y: inner.midY - text.size.height / 2,
            width: inner.width,
            height: text.size.height + 1
        )
        text.string.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private func drawHoverHighlight(around patch: CGRect, glyph: CGFloat) {
        let radius = max(4, glyph * 0.5)
        let path = NSBezierPath(roundedRect: patch.insetBy(dx: -1, dy: -1), xRadius: radius, yRadius: radius)
        path.lineWidth = 2
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }
}

/// Dashed outlines with "…" over balloons whose translation is on its way,
/// pulsing gently. A separate view so the pulse animates only these marks,
/// not the finished translations around them.
private final class PendingBubblesView: NSView {
    private var rects: [CGRect] = []
    private var glyph: CGFloat = 12

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(rects: [CGRect], glyph: CGFloat) {
        guard rects != self.rects || glyph != self.glyph else { return }
        self.rects = rects
        self.glyph = glyph
        isHidden = rects.isEmpty
        needsDisplay = true
        updatePulse()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulse()
    }

    private func updatePulse() {
        guard let layer else { return }
        let key = "pendingPulse"
        if rects.isEmpty || window == nil {
            layer.removeAnimation(forKey: key)
        } else if layer.animation(forKey: key) == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: key)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        for rect in rects where rect.intersects(dirtyRect) {
            let radius = max(4, glyph * 0.5)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            accent.withAlphaComponent(0.9).setStroke()
            path.stroke()

            let size = max(10, min(glyph, rect.height * 0.5))
            let dots = NSAttributedString(string: "…", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: accent,
            ])
            let dotsSize = dots.size()
            dots.draw(at: CGPoint(x: rect.midX - dotsSize.width / 2, y: rect.midY - dotsSize.height / 2))
        }
    }
}
