import Testing
import Foundation
import AppKit
@testable import Panely

@MainActor
struct ViewerControllerTests {

    @Test func zoomInMultipliesMagnificationByStep() {
        let sv = makeScrollView()
        sv.magnification = 1.0
        let controller = ViewerController()
        controller.attach(scrollView: sv)

        controller.zoomIn()
        #expect(abs(sv.magnification - 1.25) < 0.001)

        controller.zoomIn()
        #expect(abs(sv.magnification - 1.5625) < 0.001)
    }

    @Test func zoomOutDividesMagnificationByStep() {
        let sv = makeScrollView()
        sv.magnification = 1.0
        let controller = ViewerController()
        controller.attach(scrollView: sv)

        controller.zoomOut()
        #expect(abs(sv.magnification - 0.8) < 0.001)
    }

    @Test func zoomInClampsToMaxMagnification() {
        let sv = makeScrollView()
        sv.magnification = 9.5
        let controller = ViewerController()
        controller.attach(scrollView: sv)

        controller.zoomIn() // 9.5 * 1.25 = 11.875 → clamp to 10.0 (max)
        #expect(abs(sv.magnification - 10.0) < 0.001)
    }

    @Test func zoomOutClampsToMinMagnification() {
        let sv = makeScrollView()
        sv.magnification = 0.12
        let controller = ViewerController()
        controller.attach(scrollView: sv)

        controller.zoomOut() // 0.12 / 1.25 = 0.096 → clamp to 0.1 (min)
        #expect(abs(sv.magnification - 0.1) < 0.001)
    }

    @Test func resetZoomRestoresBaseMagnification() {
        let sv = makeScrollView()
        sv.magnification = 3.0
        let controller = ViewerController()
        controller.attach(scrollView: sv)
        controller.baseMagnification = 0.4

        controller.resetZoom()
        #expect(abs(sv.magnification - 0.4) < 0.001)
    }

    @Test func methodsAreNoOpWithoutAttachedScrollView() {
        let controller = ViewerController()
        // No attach call
        controller.zoomIn()
        controller.zoomOut()
        controller.resetZoom()
        // Just verifying no crash
        #expect(controller.baseMagnification == 1.0)
    }

    private func makeScrollView() -> NSScrollView {
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        sv.allowsMagnification = true
        sv.minMagnification = 0.1
        sv.maxMagnification = 10.0
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        sv.documentView = doc
        return sv
    }
}
