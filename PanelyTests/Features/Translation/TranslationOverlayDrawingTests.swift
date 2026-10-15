import AppKit
import ObjectiveC
import Testing
@testable import Panely

/// What `TranslationOverlayView` actually paints, read back from a bitmap:
/// patches where they're laid out and nothing elsewhere, text inside its
/// patch, hidden balloons and edit marks only in edit mode, the hover ring
/// only around the balloon under the mouse — and that the partial redraws
/// it now asks for (hover, marking an area) end up exactly where a full
/// redraw would, as does an overlay updated page after page compared with a
/// new one.
@MainActor
struct TranslationOverlayDrawingTests {
    private static let pageSize = CGSize(width: 600, height: 500)
    private static let artwork = BubbleBackground(red: 0.55, green: 0.5, blue: 0.45, isUniform: false)

    // Two balloons stacked 10 px apart: the upper one's hover ring is
    // repainted inside the lower one's feathered edge.
    private static let upper = TranslatedBubble(
        id: 0, rect: CGRect(x: 60, y: 40, width: 220, height: 40), glyphSize: 30, isVertical: false,
        source: "上", translation: "무슨 일이 있어도 이 전쟁을 멈추지 않으면 모두 끝이야", background: .white
    )
    private static let overArtwork = TranslatedBubble(
        id: 1, rect: CGRect(x: 60, y: 108, width: 220, height: 40), glyphSize: 30, isVertical: false,
        source: "下", translation: "Over the drawing", background: artwork
    )
    private static let hidden = TranslatedBubble(
        id: 2, rect: CGRect(x: 360, y: 40, width: 160, height: 70), glyphSize: 24, isVertical: false,
        source: "隠", translation: "숨김", background: .white,
        edit: BubbleEditState(correctedSource: nil, translationIsReaders: false, needsRetranslation: false, isHidden: true)
    )
    private static let edited = TranslatedBubble(
        id: 3, rect: CGRect(x: 360, y: 200, width: 180, height: 100), glyphSize: 28, isVertical: false,
        source: "編", translation: "내가 고친 번역", background: .white,
        edit: BubbleEditState(correctedSource: nil, translationIsReaders: true, needsRetranslation: false)
    )
    private static let pending = TranslatedBubble(
        id: 4, rect: CGRect(x: 60, y: 300, width: 160, height: 50), glyphSize: 24, isVertical: false,
        source: "待", translation: nil, background: .white
    )

    private static func page(_ bubbles: [TranslatedBubble]) -> TranslatedPage {
        var page = TranslatedPage(imageWidth: pageSize.width, imageHeight: pageSize.height, bubbles: bubbles, isComplete: false)
        page.pageID = "p1"
        return page
    }

    /// As reading shows it (hidden balloons left out) and as edit mode does.
    private static let readingPage = page([upper, overArtwork, edited, pending])
    private static let editingPage = page([upper, overArtwork, hidden, edited, pending])

    private func makeOverlay(_ page: TranslatedPage, editing: Bool = false, scale: CGFloat = 1) -> TranslationOverlayView {
        let overlay = TranslationOverlayView(frame: CGRect(origin: .zero, size: CGSize(width: Self.pageSize.width * scale, height: Self.pageSize.height * scale)))
        overlay.update(page: page, showsTranslation: true, isEditing: editing, pageOrigin: .zero, scale: scale)
        return overlay
    }

    // MARK: - Pixels

    private struct Pixels: Equatable {
        let width: Int
        let height: Int
        var data: [UInt8]

        func alpha(_ x: Int, _ y: Int) -> UInt8 { data[(y * width + x) * 4 + 3] }
        func isInk(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return data[i + 3] > 200 && max(data[i], data[i + 1], data[i + 2]) < 90
        }
    }

    /// `rect` of the view drawn the way the window would: just that area,
    /// into a clear bitmap.
    private func render(_ view: NSView, _ rect: CGRect? = nil) -> Pixels {
        let area = rect ?? view.bounds
        let width = Int(area.width), height = Int(area.height)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        )!
        rep.size = area.size
        view.cacheDisplay(in: area, to: rep)
        return Pixels(width: width, height: height, data: Array(UnsafeBufferPointer(start: rep.bitmapData, count: width * height * 4)))
    }

    /// What's on screen after the view redraws only `dirty` over `before`:
    /// each area cleared and drawn again, the rest left as it was.
    private func redraw(_ view: NSView, over before: Pixels, dirty: [CGRect]) -> Pixels {
        var after = before
        for rect in dirty {
            let area = NSIntegralRect(rect).intersection(view.bounds)
            guard !area.isEmpty else { continue }
            let piece = render(view, area)
            for row in 0..<piece.height {
                let source = row * piece.width * 4
                let target = ((Int(area.minY) + row) * before.width + Int(area.minX)) * 4
                after.data.replaceSubrange(target..<(target + piece.width * 4), with: piece.data[source..<(source + piece.width * 4)])
            }
        }
        return after
    }

    /// Points where two renders differ by more than `tolerance` in a channel.
    private func differences(_ a: Pixels, _ b: Pixels, tolerance: Int = 0) -> [CGPoint] {
        var points: [CGPoint] = []
        let rowBytes = a.width * 4
        a.data.withUnsafeBufferPointer { a in
            b.data.withUnsafeBufferPointer { b in
                for y in 0..<(a.count / rowBytes) {
                    let row = y * rowBytes
                    // Most rows are the same: skip them whole.
                    guard memcmp(a.baseAddress! + row, b.baseAddress! + row, rowBytes) != 0 else { continue }
                    for x in 0..<(rowBytes / 4) {
                        let i = row + x * 4
                        let delta = max(
                            abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])),
                            abs(Int(a[i + 2]) - Int(b[i + 2])), abs(Int(a[i + 3]) - Int(b[i + 3]))
                        )
                        if delta > tolerance { points.append(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) }
                    }
                }
            }
        }
        return points
    }

    private func largestDifference(_ a: Pixels, _ b: Pixels) -> Int {
        zip(a.data, b.data).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    /// Run `change` and check that what it asked to redraw covers everything
    /// that changed, and that redrawing just that gives the full picture.
    private func expectPartialRedraw(of overlay: TranslationOverlayView, _ what: String, around expected: CGRect? = nil, _ change: () -> Void) {
        let before = render(overlay)
        InvalidationRecorder.reset()
        change()
        let dirty = InvalidationRecorder.rects
        let after = render(overlay)
        let changed = differences(before, after)
        #expect(!changed.isEmpty, "\(what): something changes")
        #expect(!InvalidationRecorder.didInvalidateEverything, "\(what): only part is redrawn")
        let outside = changed.filter { point in !dirty.contains { NSIntegralRect($0).contains(point) } }
        #expect(outside.isEmpty, "\(what): \(outside.count) changed pixels outside the redrawn areas, first \(outside.first.map { "\($0)" } ?? "")")
        if let expected {
            #expect(changed.allSatisfy { expected.contains($0) }, "\(what): changes only around \(expected)")
        }
        let partial = redraw(overlay, over: before, dirty: dirty)
        // A clipped redraw can round an edge pixel one level differently.
        let mismatched = differences(partial, after, tolerance: 2)
        #expect(mismatched.isEmpty, "\(what): \(mismatched.count) pixels differ from a full redraw by up to \(largestDifference(partial, after)), at \(mismatched.prefix(5).map { "\($0)" })")
    }

    // MARK: - Events

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .mouseMoved ? 0 : 1
        )!
    }

    private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    // MARK: - Structure

    @Test func patchesAndTheirTextAreDrawnWhereLaidOutAndNowhereElse() {
        let overlay = makeOverlay(Self.readingPage)
        let pixels = render(overlay)
        let layout = TranslationOverlayLayout.layout(for: Self.readingPage)
        #expect(layout.drawn.count == 3)

        for (bubble, patch) in layout.drawn {
            // Painted through the middle.
            let middle = patch.insetBy(dx: patch.width * 0.3, dy: patch.height * 0.3)
            #expect(pixels.alpha(Int(middle.minX), Int(middle.minY)) > 200, "patch of \(bubble.id) painted")
            #expect(pixels.alpha(Int(middle.maxX), Int(middle.maxY)) > 200, "patch of \(bubble.id) painted")
            // Text, all of it inside the patch's inner area.
            let inner = patch.insetBy(dx: bubble.glyphSize * 0.3, dy: bubble.glyphSize * 0.3).insetBy(dx: -2, dy: -2)
            var ink = 0
            var stray = 0
            for y in Int(patch.minY)..<Int(patch.maxY) {
                for x in Int(patch.minX)..<Int(patch.maxX) where pixels.isInk(x, y) {
                    ink += 1
                    if !inner.contains(CGPoint(x: x, y: y)) { stray += 1 }
                }
            }
            #expect(ink > 50, "text of \(bubble.id) drawn")
            #expect(stray == 0, "text of \(bubble.id) stays in its patch: \(stray) pixels outside")
        }

        // Nothing past the patches: a uniform patch has a hard edge, a
        // feathered one fades within its blur; the pending balloon is outlined.
        var painted: [CGRect] = layout.drawn.map { bubble, patch in
            bubble.background.isUniform ? patch.insetBy(dx: -1, dy: -1) : patch.insetBy(dx: -40, dy: -40)
        }
        painted.append(TranslationOverlayLayout.patchRect(for: Self.pending, imageSize: Self.pageSize).insetBy(dx: -2, dy: -2))
        var outside = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.alpha(x, y) != 0 && !painted.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) {
                outside += 1
            }
        }
        #expect(outside == 0, "\(outside) pixels painted outside every patch")

        // The pending balloon: outlined, its middle left alone.
        let pendingPatch = TranslationOverlayLayout.patchRect(for: Self.pending, imageSize: Self.pageSize)
        let pendingOutline = (Int(pendingPatch.minY)..<Int(pendingPatch.maxY)).filter { pixels.alpha(Int(pendingPatch.minX) + 1, $0) > 0 }
        #expect(pendingOutline.count > 10, "dashed outline down its left side")
        #expect(pixels.alpha(Int(pendingPatch.minX + 12), Int(pendingPatch.minY + 8)) == 0)
    }

    @Test func hiddenBalloonsAndEditMarksShowOnlyInEditMode() throws {
        let reading = render(makeOverlay(Self.readingPage))
        let editing = render(makeOverlay(Self.editingPage, editing: true))
        let layout = TranslationOverlayLayout.layout(for: Self.editingPage)
        let hiddenPatch = try #require(layout.patches[Self.hidden.id])
        let editedArea = try #require(layout.hitAreas[Self.edited.id])
        let badgeSize = min(max(12, editedArea.height * 0.16), 18)
        let badge = CGRect(x: editedArea.maxX - badgeSize - 3, y: editedArea.minY + 3, width: badgeSize, height: badgeSize)

        // The hidden balloon isn't painted: the original shows through,
        // framed by a dashed outline.
        #expect(!layout.drawn.contains { $0.bubble.id == Self.hidden.id })
        #expect(editing.alpha(Int(hiddenPatch.midX), Int(hiddenPatch.midY)) == 0)
        let outline = (Int(hiddenPatch.minY)..<Int(hiddenPatch.maxY)).filter { editing.alpha(Int(hiddenPatch.minX) + 1, $0) > 0 }
        #expect(outline.count > 10, "dashed outline down its left side")

        // Everything edit mode adds is the outline and the badge.
        let changed = differences(reading, editing)
        let marks = [hiddenPatch.insetBy(dx: -2, dy: -2), badge.insetBy(dx: -2, dy: -2)]
        #expect(changed.allSatisfy { point in marks.contains { $0.contains(point) } }, "edit mode changes only its marks")
        #expect(changed.contains { badge.contains($0) }, "the edited balloon has its badge")
        #expect(changed.contains { hiddenPatch.contains($0) }, "the hidden balloon has its outline")
    }

    // MARK: - Partial redraws

    @Test func hoveringRedrawsOnlyTheRingsAndMatchesAFullRedraw() {
        let overlay = makeOverlay(Self.readingPage)
        InvalidationRecorder.install(on: overlay)
        let layout = TranslationOverlayLayout.layout(for: Self.readingPage)
        let upper = layout.hitAreas[Self.upper.id]!
        let lower = layout.hitAreas[Self.overArtwork.id]!
        let edited = layout.hitAreas[Self.edited.id]!

        expectPartialRedraw(of: overlay, "hovering the upper balloon", around: upper.insetBy(dx: -4, dy: -4)) {
            overlay.mouseMoved(with: event(.mouseMoved, at: center(upper), in: overlay))
        }
        expectPartialRedraw(of: overlay, "moving to the balloon over artwork") {
            overlay.mouseMoved(with: event(.mouseMoved, at: center(lower), in: overlay))
        }
        expectPartialRedraw(of: overlay, "moving across the page", around: lower.union(edited).insetBy(dx: -4, dy: -4)) {
            overlay.mouseMoved(with: event(.mouseMoved, at: center(edited), in: overlay))
        }
        expectPartialRedraw(of: overlay, "moving off the balloons", around: edited.insetBy(dx: -4, dy: -4)) {
            overlay.mouseMoved(with: event(.mouseMoved, at: CGPoint(x: 590, y: 490), in: overlay))
        }
        // Back to how it started.
        #expect(render(overlay) == render(makeOverlay(Self.readingPage)))
    }

    @Test func markingOutABalloonRedrawsWhereTheAreaWasAndIs() {
        let overlay = makeOverlay(Self.editingPage, editing: true)
        InvalidationRecorder.install(on: overlay)
        var requested: [TranslationEditChange] = []
        overlay.onEdit = { requested.append($0.change) }
        let start = CGPoint(x: 300, y: 330)

        overlay.mouseDown(with: event(.leftMouseDown, at: start, in: overlay))
        expectPartialRedraw(of: overlay, "dragging out an area") {
            overlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 500, y: 460), in: overlay))
        }
        expectPartialRedraw(of: overlay, "shrinking it") {
            overlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 360, y: 380), in: overlay))
        }
        expectPartialRedraw(of: overlay, "letting go") {
            overlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 360, y: 380), in: overlay))
        }
        #expect(requested == [.addBalloon(CGRect(x: 300, y: 330, width: 60, height: 50))])
        #expect(render(overlay) == render(makeOverlay(Self.editingPage, editing: true)))
    }

    /// The stack sizes each overlay from the layout the overlay then draws
    /// with (`preparedLayout`): a page whose balloon comes to reach past it
    /// grows the overlay, and shrinks it again when it no longer does.
    @Test func theOverlayFollowsItsPageAsBalloonsComeAndGo() throws {
        let size = CGSize(width: 1000, height: 2000)
        func page(reachingPast: Bool) -> TranslatedPage {
            var page = TranslatedPage(imageWidth: size.width, imageHeight: size.height, bubbles: [
                TranslatedBubble(id: 0, rect: CGRect(x: 600, y: 400, width: 200, height: 300), glyphSize: 40, isVertical: false, source: "原文", translation: "번역", background: .white),
            ])
            if reachingPast {
                page.bubbles.append(TranslatedBubble(id: 1, rect: CGRect(x: 100, y: 1800, width: 200, height: 500), glyphSize: 40, isVertical: false, source: "下", translation: "아래", background: .white))
            }
            page.pageID = "p1"
            return page
        }
        let stack = ImageStackView()
        stack.setImages([NSImage(size: size), NSImage(size: size)], axis: .vertical)
        stack.refreshVisibleViews(visibleRect: CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height * 2)))
        func overlay() throws -> TranslationOverlayView { try #require(stack.subviews.compactMap { $0 as? TranslationOverlayView }.first) }

        stack.setTranslationOverlay([page(reachingPast: false), nil], showsTranslation: true)
        let plain = try overlay()
        #expect(plain.frame == CGRect(origin: .zero, size: size))

        stack.setTranslationOverlay([page(reachingPast: true), nil], showsTranslation: true)
        let grown = try overlay()
        #expect(grown === plain)
        #expect(grown.frame.minY == 0 && grown.frame.maxY >= 2300 - 1)
        #expect(stack.hitTest(stack.convert(NSPoint(x: 200, y: 2200), to: nil)) === grown)

        stack.setTranslationOverlay([page(reachingPast: false), nil], showsTranslation: true)
        let shrunk = try overlay()
        #expect(shrunk.frame == CGRect(origin: .zero, size: size))
    }

    // MARK: - Updates

    /// A job fills a page in a balloon at a time, and the overlay keeps its
    /// layout and fitted text between updates. Whatever it kept, an updated
    /// overlay must draw exactly what a new one would.
    @Test func anOverlayUpdatedStepByStepDrawsLikeANewOne() {
        var neighbour = TranslatedBubble(
            id: 5, rect: CGRect(x: 300, y: 40, width: 40, height: 220), glyphSize: 30, isVertical: true,
            source: "隣", translation: nil, background: .white
        )
        var first = Self.upper
        first.rect = CGRect(x: 200, y: 40, width: 40, height: 220)
        first.isVertical = true
        first.translation = nil
        var steps: [(String, TranslatedPage, CGFloat)] = []
        var bubbles = [first]
        steps.append(("a balloon found", Self.page(bubbles), 1))
        // Long enough that its size is set by the patch's width.
        bubbles[0].translation = "처음엔 넓은 자리에 그려지는 아주 긴 번역 문장이라서 자리가 좁아지면 글자도 작아져야 합니다"
        steps.append(("its translation", Self.page(bubbles), 1))
        bubbles.append(neighbour)
        // The neighbour's arrival cuts the first patch back: refitted.
        steps.append(("a neighbour found", Self.page(bubbles), 1))
        neighbour.translation = "옆"
        bubbles[1] = neighbour
        steps.append(("the neighbour translated", Self.page(bubbles), 1))
        steps.append(("zoomed in", Self.page(bubbles), 1.5))
        bubbles[0].translation = "고친 번역"
        steps.append(("a translation changed", Self.page(bubbles), 1.5))
        bubbles[0].background = Self.artwork
        steps.append(("its tone resampled", Self.page(bubbles), 1.5))
        bubbles.remove(at: 1)
        steps.append(("the neighbour gone", Self.page(bubbles), 1.5))
        steps.append(("zoomed back", Self.page(bubbles), 1))

        let updated = makeOverlay(steps[0].1)
        let firstPatches = steps.map { TranslationOverlayLayout.layout(for: $0.1).patches[0]?.width }
        #expect(firstPatches[1] != firstPatches[2], "the neighbour changes the first patch")
        for (what, page, scale) in steps {
            let size = CGSize(width: Self.pageSize.width * scale, height: Self.pageSize.height * scale)
            updated.frame = CGRect(origin: .zero, size: size)
            updated.update(page: page, showsTranslation: true, pageOrigin: .zero, scale: scale)
            let drawn = render(updated)
            let fresh = render(makeOverlay(page, scale: scale))
            let mismatched = differences(drawn, fresh).count
            #expect(mismatched == 0, "\(what): \(mismatched) pixels differ from a new overlay")
        }
    }
}

/// Records what a view asks to redraw. The overlay is `final`, so instead
/// of a subclass in Swift its instance is moved to a runtime subclass whose
/// `setNeedsDisplay` calls note the area and go on as before.
@MainActor
enum InvalidationRecorder {
    nonisolated(unsafe) private(set) static var rects: [CGRect] = []
    nonisolated(unsafe) private(set) static var didInvalidateEverything = false

    static func reset() {
        rects = []
        didInvalidateEverything = false
    }

    static func install(on view: TranslationOverlayView) {
        object_setClass(view, recordingClass)
    }

    private static let recordingClass: AnyClass = {
        let base: AnyClass = TranslationOverlayView.self
        let name = "PanelyTestsRecordingTranslationOverlayView"
        if let existing = NSClassFromString(name) { return existing }
        let subclass: AnyClass = objc_allocateClassPair(base, name, 0)!

        let inRect = NSSelectorFromString("setNeedsDisplayInRect:")
        typealias InRect = @convention(c) (AnyObject, Selector, NSRect) -> Void
        let originalInRect = unsafeBitCast(class_getMethodImplementation(base, inRect), to: InRect.self)
        let recordRect: @convention(block) (AnyObject, NSRect) -> Void = { view, rect in
            InvalidationRecorder.rects.append(rect)
            originalInRect(view, inRect, rect)
        }
        class_addMethod(subclass, inRect, imp_implementationWithBlock(recordRect), method_getTypeEncoding(class_getInstanceMethod(base, inRect)!))

        let flag = NSSelectorFromString("setNeedsDisplay:")
        typealias Flag = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        let originalFlag = unsafeBitCast(class_getMethodImplementation(base, flag), to: Flag.self)
        let recordFlag: @convention(block) (AnyObject, ObjCBool) -> Void = { view, needed in
            if needed.boolValue {
                InvalidationRecorder.didInvalidateEverything = true
                InvalidationRecorder.rects.append(CGRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6))
            }
            originalFlag(view, flag, needed)
        }
        class_addMethod(subclass, flag, imp_implementationWithBlock(recordFlag), method_getTypeEncoding(class_getInstanceMethod(base, flag)!))

        objc_registerClassPair(subclass)
        return subclass
    }()
}
