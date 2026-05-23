import Testing
import Foundation
import AppKit
@testable import Panely

@MainActor
struct CenteringClipViewTests {
    @Test func centersBothAxesWhenDocumentIsSmaller() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.contentView = CenteringClipView()
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let bounds = scrollView.contentView.bounds
        // Document (400x300) centered in clip bounds (800x600).
        // Expected origin = docMid - clipSize/2 = (200-400, 150-300) = (-200, -150)
        #expect(abs(bounds.origin.x - (-200)) < 1.0)
        #expect(abs(bounds.origin.y - (-150)) < 1.0)
    }

    @Test func centersOnlyOnTheAxisWhereDocumentIsSmaller() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.contentView = CenteringClipView()
        // Document is narrower than clip (400 < 800) but taller than clip (900 > 600)
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let bounds = scrollView.contentView.bounds
        // Horizontal centering: origin.x = 200 - 400 = -200
        #expect(abs(bounds.origin.x - (-200)) < 1.0)
        // Vertical: super's constrain keeps origin.y >= 0 (document scrollable)
        #expect(bounds.origin.y >= 0)
    }

    @Test func doesNotCenterWhenDocumentIsLargerThanClip() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.contentView = CenteringClipView()
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let bounds = scrollView.contentView.bounds
        // Both axes larger in doc → no centering offset, origin stays at default (>= 0)
        #expect(bounds.origin.x >= 0)
        #expect(bounds.origin.y >= 0)
    }
}
