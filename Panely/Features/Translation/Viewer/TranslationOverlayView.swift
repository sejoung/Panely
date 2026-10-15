import AppKit
import QuartzCore
import SwiftUI

/// Draws one page's translations over the original and makes each balloon
/// clickable: a click opens the original next to its translation.
///
/// In edit mode (`isEditing`) the popover also corrects the balloon
/// (`onEdit`), edited balloons carry a pencil badge, and hidden balloons are
/// drawn as dashed outlines — a click brings one back. Reading shows none of
/// that, only the translation.
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
///
/// In edit mode the rest of the page takes drags too: dragging over text
/// the analysis missed marks it out, and a balloon is added there
/// (`.addBalloon`). The page doesn't pan by dragging while editing; scrolling
/// and double-click zoom still work.
final class TranslationOverlayView: NSView {
    private(set) var page: TranslatedPage?
    private(set) var showsTranslation = false
    private(set) var isEditing = false
    /// Set when a reading popover asked for edit mode: that balloon's popover
    /// reopens, with its edits, once the overlay is in edit mode.
    private var reopenForEditingBubbleID: Int?
    /// A correction made in a balloon's popover.
    var onEdit: ((TranslationEditRequest) -> Void)?
    private var pageOrigin: CGPoint = .zero
    private var scale: CGFloat = 1

    private var hoveredBubbleID: Int?
    /// Where a drag marking out a new balloon started, and the area so far
    /// (view coordinates).
    private var markStart: NSPoint?
    private var markedArea: CGRect?
    /// Smaller than this (view points) is a click, not an area.
    static let minimumMarkSide: CGFloat = 12
    private var popover: NSPopover?
    private var pendingPopover: Task<Void, Never>?
    private var trackingArea: NSTrackingArea?
    private let pendingView = PendingBubblesView()
    /// Fitted text per balloon, valid for `fittedForScale`. Fitting is a small
    /// binary search per balloon; redraws (hover, scroll) reuse it.
    private var fittedText: [Int: TranslationPatchPainter.Fitted] = [:]
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
    func update(page: TranslatedPage?, showsTranslation: Bool, isEditing: Bool = false, pageOrigin: CGPoint, scale: CGFloat) {
        let geometryChanged = pageOrigin != self.pageOrigin || scale != self.scale
        let modeChanged = isEditing != self.isEditing
        guard page != self.page || showsTranslation != self.showsTranslation || modeChanged || geometryChanged else { return }
        if page?.bubbles.map(\.id) != self.page?.bubbles.map(\.id) {
            hoveredBubbleID = nil
        }
        // The open popover belongs to the other mode.
        if page == nil || modeChanged { closePopover() }
        self.page = page
        self.showsTranslation = showsTranslation
        self.isEditing = isEditing
        self.pageOrigin = pageOrigin
        self.scale = scale
        pendingView.update(rects: pendingRects(), glyph: pendingGlyph())
        needsDisplay = true
        if isEditing, let id = reopenForEditingBubbleID {
            reopenForEditingBubbleID = nil
            showPopover(forBubbleID: id)
        }
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

    /// The page itself, in this view.
    private var pageInView: CGRect {
        guard let page else { return .zero }
        return CGRect(x: pageOrigin.x, y: pageOrigin.y, width: page.imageWidth * scale, height: page.imageHeight * scale)
    }

    /// Edit mode, over the page but not a balloon: a drag here marks out a
    /// balloon to add.
    private func canMark(at point: NSPoint) -> Bool {
        isEditing && page?.pageID != nil && pageInView.contains(point) && bubble(at: point) == nil
    }

    private func pendingRects() -> [CGRect] {
        guard let page else { return [] }
        return page.bubbles.filter { $0.translation == nil && $0.edit?.isHidden != true }.map(patchInView)
    }

    private func pendingGlyph() -> CGFloat {
        guard let glyph = page?.bubbles.first(where: { $0.translation == nil })?.glyphSize else { return 12 }
        return CGFloat(glyph) * scale
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        return bubble(at: local) != nil || canMark(at: local) ? self : nil
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
        let point = convert(event.locationInWindow, from: nil)
        setHovered(bubble(at: point)?.id)
        if hoveredBubbleID == nil, canMark(at: point) { NSCursor.crosshair.set() }
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
        let point = convert(event.locationInWindow, from: nil)
        guard let bubble = bubble(at: point) else {
            if canMark(at: point) {
                markStart = point
                markedArea = nil
            } else {
                superview?.mouseDown(with: event)
            }
            return
        }
        // Wait out the double-click interval so a zoom double-click on a
        // balloon doesn't flash a popover first.
        pendingPopover?.cancel()
        let bubbleID = bubble.id
        pendingPopover = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled, let self else { return }
            if bubble.edit?.isHidden == true {
                // A hidden balloon's outline: clicking it brings it back.
                guard let pageID = self.page?.pageID else { return }
                self.onEdit?(TranslationEditRequest(pageID: pageID, bubble: bubble, change: .show))
            } else {
                self.showPopover(forBubbleID: bubbleID)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let markStart else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let area = CGRect(
            x: min(markStart.x, point.x), y: min(markStart.y, point.y),
            width: abs(point.x - markStart.x), height: abs(point.y - markStart.y)
        ).intersection(pageInView)
        markedArea = area.isNull ? nil : area
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            markStart = nil
            if markedArea != nil {
                markedArea = nil
                needsDisplay = true
            }
        }
        guard markStart != nil else {
            super.mouseUp(with: event)
            return
        }
        guard let area = markedArea, let pageID = page?.pageID,
              area.width >= Self.minimumMarkSide, area.height >= Self.minimumMarkSide else { return }
        markBalloon(area, pageID: pageID)
    }

    /// Ask for a balloon over `area` (view coordinates).
    func markBalloon(_ area: CGRect, pageID: String) {
        let inPage = CGRect(
            x: (area.minX - pageOrigin.x) / scale,
            y: (area.minY - pageOrigin.y) / scale,
            width: area.width / scale,
            height: area.height / scale
        )
        // No balloon yet: one stands in for the area.
        let placeholder = TranslatedBubble(
            id: -1, rect: inPage, glyphSize: 0, isVertical: false, source: "", translation: nil, background: .white
        )
        onEdit?(TranslationEditRequest(pageID: pageID, bubble: placeholder, change: .addBalloon(inPage)))
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
        let pageID = page?.pageID
        let host = NSHostingController(
            rootView: TranslationBubblePopover(
                source: bubble.source,
                translation: bubble.translation,
                alternates: bubble.alternates ?? [:],
                edit: bubble.edit,
                isEditing: isEditing,
                onEdit: pageID == nil ? nil : { [weak self] change in
                    // Return can reach both the field and the default button;
                    // the first one closes the popover and wins.
                    guard let self, let pageID, self.popover != nil else { return }
                    self.closePopover()
                    if change == .enterEditMode { self.reopenForEditingBubbleID = bubble.id }
                    self.onEdit?(TranslationEditRequest(pageID: pageID, bubble: bubble, change: change))
                },
                onEditingChanged: { [weak self] isEditing in
                    // A stray click outside mustn't throw away what's typed.
                    self?.popover?.behavior = isEditing ? .applicationDefined : .transient
                }
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
            if bubble.edit?.isHidden == true {
                drawHiddenOutline(around: patch, glyph: CGFloat(bubble.glyphSize) * scale)
            } else {
                if showsTranslation, let translation = bubble.translation, !translation.isEmpty {
                    drawTranslation(translation, of: bubble, in: patch)
                }
                if showsTranslation, isEditing, bubble.edit != nil {
                    drawEditBadge(in: patch)
                }
            }
            if bubble.id == hoveredBubbleID {
                drawHoverHighlight(around: patch, glyph: CGFloat(bubble.glyphSize) * scale)
            }
        }
        if let markedArea {
            drawMarkedArea(markedArea)
        }
    }

    /// The area being dragged out for a new balloon.
    private func drawMarkedArea(_ area: CGRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        area.fill()
        let path = NSBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func drawTranslation(_ translation: String, of bubble: TranslatedBubble, in patch: CGRect) {
        fittedText[bubble.id] = TranslationPatchPainter.draw(
            translation,
            background: bubble.background,
            glyph: CGFloat(bubble.glyphSize) * scale,
            in: patch,
            fitted: fittedText[bubble.id]
        )
    }

    /// Edit mode: where a hidden balloon is — the original shows through,
    /// framed by a dashed line with an eye-slash, and a click brings it back.
    private func drawHiddenOutline(around patch: CGRect, glyph: CGFloat) {
        let radius = max(4, glyph * 0.5)
        let path = NSBezierPath(roundedRect: patch.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        path.lineWidth = 1.5
        path.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.systemGray.withAlphaComponent(0.9).setStroke()
        path.stroke()
        let size = min(max(12, patch.height * 0.16), 18)
        guard patch.width > size * 2, patch.height > size * 1.5 else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.7, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemGray]))
        guard let eye = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let rect = CGRect(x: patch.maxX - eye.size.width - 4, y: patch.minY + 4, width: eye.size.width, height: eye.size.height)
        eye.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Edit mode: a small pencil in the corner of a balloon the reader
    /// changed, so edits can be told apart (and found again to revert)
    /// without opening every balloon.
    private func drawEditBadge(in patch: CGRect) {
        let size = min(max(12, patch.height * 0.16), 18)
        guard patch.width > size * 2, patch.height > size * 1.5 else { return }
        let badge = CGRect(x: patch.maxX - size - 3, y: patch.minY + 3, width: size, height: size)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: badge).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let glyph = CGRect(
            x: badge.midX - pencil.size.width / 2,
            y: badge.midY - pencil.size.height / 2,
            width: pencil.size.width,
            height: pencil.size.height
        )
        pencil.draw(in: glyph, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
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
