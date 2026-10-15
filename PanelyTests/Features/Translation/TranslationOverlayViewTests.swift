import AppKit
import Testing
@testable import Panely

/// The overlay must take clicks on balloons — and only there, so scrolling,
/// panning and double-click zoom everywhere else still reach the viewer.
@MainActor
struct TranslationOverlayViewTests {
    private let imageSize = CGSize(width: 1000, height: 2000)
    private let balloon = CGRect(x: 600, y: 400, width: 200, height: 300)

    private func page(imageSize: CGSize? = nil) -> TranslatedPage {
        let size = imageSize ?? self.imageSize
        return TranslatedPage(
            imageWidth: size.width,
            imageHeight: size.height,
            bubbles: [
                TranslatedBubble(
                    id: 0, rect: balloon, glyphSize: 40, isVertical: false,
                    source: "原文", translation: "번역", background: .white
                ),
            ]
        )
    }

    private func makeStack(overlay: TranslatedPage?) -> ImageStackView {
        let stack = ImageStackView()
        stack.setImages([NSImage(size: imageSize)], axis: .horizontal)
        stack.setTranslationOverlay([overlay], showsTranslation: true)
        return stack
    }

    /// Hit-test a point given in the stack's own (flipped) coordinates.
    /// `hitTest` takes the *superview's* coordinates; for a parentless view
    /// that's window space, which isn't flipped.
    private func hit(_ stack: ImageStackView, _ point: NSPoint) -> NSView? {
        stack.hitTest(stack.convert(point, to: nil))
    }

    private func overlays(in stack: ImageStackView) -> [TranslationOverlayView] {
        stack.subviews.compactMap { $0 as? TranslationOverlayView }
    }

    @Test func overlayAttachesToItsPageAndTakesBalloonClicks() throws {
        let stack = makeStack(overlay: page())
        let overlay = try #require(overlays(in: stack).first)
        #expect(overlay.page == page())
        #expect(overlay.showsTranslation)

        // The stack lays the page out at its native size, so page pixels are
        // stack points here.
        #expect(hit(stack, NSPoint(x: balloon.midX, y: balloon.midY)) === overlay)

        let elsewhere = hit(stack, NSPoint(x: 100, y: 1500))
        #expect(elsewhere !== overlay)
        #expect(elsewhere is NSImageView)
    }

    @Test func overlaySitsAboveEveryImage() throws {
        let stack = makeStack(overlay: page())
        let overlay = try #require(overlays(in: stack).first)
        #expect(stack.subviews.last === overlay)
    }

    @Test func stripBalloonCrossingIntoTheNextSliceExtendsTheOverlay() throws {
        // A balloon starting near the bottom of a 2000 px slice and running
        // 300 px past it.
        var crossing = page()
        crossing.bubbles[0].rect = CGRect(x: 600, y: 1800, width: 200, height: 500)
        // Two slices stacked as in the vertical layout.
        let stack = ImageStackView()
        stack.setImages([NSImage(size: imageSize), NSImage(size: imageSize)], axis: .vertical)
        stack.setTranslationOverlay([crossing, nil], showsTranslation: true)
        stack.refreshVisibleViews(visibleRect: CGRect(origin: .zero, size: CGSize(width: imageSize.width, height: imageSize.height * 2)))
        let overlay = try #require(overlays(in: stack).first)

        #expect(overlay.frame.minY == 0)
        #expect(overlay.frame.maxY > imageSize.height + 250)
        #expect(hit(stack, NSPoint(x: 700, y: 2200)) === overlay)
    }

    @Test func pendingBalloonsAreStillClickable() throws {
        var pending = page()
        pending.bubbles[0].translation = nil
        let stack = makeStack(overlay: pending)
        let overlay = try #require(overlays(in: stack).first)
        #expect(hit(stack, NSPoint(x: balloon.midX, y: balloon.midY)) === overlay)
    }

    @Test func noOverlayWithoutATranslation() {
        let stack = makeStack(overlay: nil)
        #expect(overlays(in: stack).isEmpty)
    }

    @Test func overlayForADifferentlySizedImageIsNotShown() {
        // Paged mode swaps images only after decode; a translation meant for
        // the next page must not be drawn over the current one.
        let stack = makeStack(overlay: page(imageSize: CGSize(width: 800, height: 1200)))
        #expect(overlays(in: stack).isEmpty)
    }

    @Test func clearingTheOverlayRemovesIt() {
        let stack = makeStack(overlay: page())
        stack.setTranslationOverlay([], showsTranslation: false)
        #expect(overlays(in: stack).isEmpty)
    }

    @Test func hidingTranslationKeepsBalloonsClickable() throws {
        let stack = makeStack(overlay: page())
        stack.setTranslationOverlay([page()], showsTranslation: false)
        let overlay = try #require(overlays(in: stack).first)

        #expect(overlay.showsTranslation == false)
        #expect(hit(stack, NSPoint(x: balloon.midX, y: balloon.midY)) === overlay)
    }
}


/// Marking out a balloon to add, in edit mode.
@MainActor
struct TranslationOverlayMarkingTests {
    private let imageSize = CGSize(width: 1000, height: 2000)

    private func makeOverlay(editing: Bool) -> (ImageStackView, TranslationOverlayView) {
        var page = TranslatedPage(imageWidth: 1000, imageHeight: 2000, bubbles: [])
        page.pageID = "p1"
        let stack = ImageStackView()
        stack.setImages([NSImage(size: imageSize)], axis: .horizontal)
        stack.setTranslationOverlay([page], showsTranslation: true, isEditing: editing)
        let overlay = stack.subviews.compactMap { $0 as? TranslationOverlayView }.first!
        return (stack, overlay)
    }

    @Test func onlyEditModeTakesTheMouseAwayFromBalloons() {
        let (reading, _) = makeOverlay(editing: false)
        #expect(!(reading.hitTest(reading.convert(NSPoint(x: 100, y: 100), to: nil)) is TranslationOverlayView))

        let (editing, overlay) = makeOverlay(editing: true)
        #expect(editing.hitTest(editing.convert(NSPoint(x: 100, y: 100), to: nil)) === overlay)
    }

    @Test func aMarkedAreaIsAskedForInPagePixels() {
        let (_, overlay) = makeOverlay(editing: true)
        var request: TranslationEditRequest?
        overlay.onEdit = { request = $0 }

        overlay.markBalloon(CGRect(x: 100, y: 200, width: 60, height: 120), pageID: "p1")

        #expect(request?.pageID == "p1")
        // The stack shows the page at its pixel size here.
        #expect(request?.change == .addBalloon(CGRect(x: 100, y: 200, width: 60, height: 120)))
    }
}

/// The right-click menu: corrections where the balloon is, page actions
/// anywhere on the page — without finding edit mode first.
@MainActor
struct TranslationOverlayMenuTests {
    private let imageSize = CGSize(width: 1000, height: 2000)
    private let balloon = CGRect(x: 600, y: 400, width: 200, height: 300)

    private func makeStack(edit: BubbleEditState? = nil, editing: Bool = false) -> (ImageStackView, TranslationOverlayView) {
        var page = TranslatedPage(imageWidth: 1000, imageHeight: 2000, bubbles: [
            TranslatedBubble(id: 0, rect: balloon, glyphSize: 40, isVertical: false, source: "原文", translation: "번역", background: .white, edit: edit),
        ])
        page.pageID = "p1"
        let stack = ImageStackView()
        stack.setImages([NSImage(size: imageSize)], axis: .horizontal)
        stack.setTranslationOverlay([page], showsTranslation: true, isEditing: editing)
        return (stack, stack.subviews.compactMap { $0 as? TranslationOverlayView }.first!)
    }

    @Test func onABalloonItsCorrectionsComeFirstThenThePage() throws {
        let (_, overlay) = makeStack()
        var changes: [TranslationEditChange] = []
        overlay.onEdit = { changes.append($0.change) }

        let menu = try #require(overlay.contextMenu(at: NSPoint(x: balloon.midX, y: balloon.midY)))
        // Edit…, Fix Original…, Hide | Translate again, AI chat, Add here | Edit mode
        #expect(menu.items.count == 9)
        for index in [2, 4, 5, 6, 8] { menu.performActionForItem(at: index) }

        #expect(changes == [.hide, .translatePageAgain, .improveWithAIChat, .startAddingBalloon, .enterEditMode])
    }

    @Test func elsewhereOnThePageOnlyThePageActions() throws {
        let (_, overlay) = makeStack(editing: true)
        var changes: [TranslationEditChange] = []
        overlay.onEdit = { changes.append($0.change) }

        let menu = try #require(overlay.contextMenu(at: NSPoint(x: 100, y: 100)))
        #expect(menu.items.count == 5)
        menu.performActionForItem(at: 4)

        #expect(changes == [.leaveEditMode])
        #expect(overlay.contextMenu(at: NSPoint(x: 100, y: 2500)) == nil)
    }

    @Test func aBalloonTheReaderAddedIsRemovedNotHidden() throws {
        let (_, overlay) = makeStack(edit: BubbleEditState(correctedSource: nil, translationIsReaders: false, needsRetranslation: false, isAdded: true))
        var changes: [TranslationEditChange] = []
        overlay.onEdit = { changes.append($0.change) }

        let menu = try #require(overlay.contextMenu(at: NSPoint(x: balloon.midX, y: balloon.midY)))
        menu.performActionForItem(at: 2)

        #expect(changes == [.remove])
    }

    @Test func aRightClickBesideTheBalloonsReachesThePagesMenu() throws {
        let (stack, _) = makeStack()
        let location = stack.convert(NSPoint(x: 100, y: 100), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        #expect(stack.menu(for: event)?.items.count == 5)
    }
}

/// Balloons drawn together still answer clicks one by one.
@MainActor
struct TranslationOverlayGroupedTests {
    @Test func eachBalloonDrawnInAGroupOpensOnItsOwn() {
        var page = TranslatedPage(imageWidth: 1000, imageHeight: 1000, bubbles: [
            TranslatedBubble(id: 0, rect: CGRect(x: 100, y: 100, width: 500, height: 80), glyphSize: 60, isVertical: false, source: "見出し", translation: "제목", background: .white),
            TranslatedBubble(id: 1, rect: CGRect(x: 520, y: 140, width: 60, height: 300), glyphSize: 40, isVertical: true, source: "小見出し", translation: "부제", background: .white),
        ])
        page.pageID = "p1"
        let stack = ImageStackView()
        stack.setImages([NSImage(size: CGSize(width: 1000, height: 1000))], axis: .horizontal)
        stack.setTranslationOverlay([page], showsTranslation: true)
        let overlay = stack.subviews.compactMap { $0 as? TranslationOverlayView }.first!
        var hidden: [Int] = []
        overlay.onEdit = { hidden.append($0.bubble.id) }

        overlay.contextMenu(at: NSPoint(x: 200, y: 140))?.performActionForItem(at: 2)
        overlay.contextMenu(at: NSPoint(x: 550, y: 400))?.performActionForItem(at: 2)

        #expect(hidden == [0, 1])
    }
}
