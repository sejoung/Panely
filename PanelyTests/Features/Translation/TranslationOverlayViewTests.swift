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
