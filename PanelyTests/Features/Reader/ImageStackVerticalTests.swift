import Testing
import Foundation
import AppKit
@testable import Panely

@MainActor
struct ImageStackVerticalTests {
    @Test func pageIndexForCenterFindsCorrectImage() {
        let stack = ImageStackView(frame: .zero)
        let images = (0..<4).map { _ in NSImage(size: NSSize(width: 1000, height: 1500)) }
        stack.setImages(images, axis: .vertical)

        // After vertical layout: image i occupies y in [i*1500, (i+1)*1500)
        #expect(stack.pageIndex(forViewportY: 750) == 0)
        #expect(stack.pageIndex(forViewportY: 1500) == 1)
        #expect(stack.pageIndex(forViewportY: 2250) == 1)
        #expect(stack.pageIndex(forViewportY: 4499) == 2)
        #expect(stack.pageIndex(forViewportY: 4500) == 3)
        #expect(stack.pageIndex(forViewportY: 5999) == 3)
    }

    @Test func pageIndexBeyondLastReturnsLastIndex() {
        let stack = ImageStackView(frame: .zero)
        let images = (0..<2).map { _ in NSImage(size: NSSize(width: 100, height: 100)) }
        stack.setImages(images, axis: .vertical)

        #expect(stack.pageIndex(forViewportY: 999_999) == 1)
    }

    @Test func pageIndexBeforeFirstReturnsZero() {
        let stack = ImageStackView(frame: .zero)
        let images = (0..<2).map { _ in NSImage(size: NSSize(width: 100, height: 100)) }
        stack.setImages(images, axis: .vertical)

        #expect(stack.pageIndex(forViewportY: -50) == 0)
    }

    @Test func emptyStackReturnsZero() {
        let stack = ImageStackView(frame: .zero)
        stack.setImages([], axis: .vertical)
        #expect(stack.pageIndex(forViewportY: 100) == 0)
    }

    @Test func incrementalUpdateSwapsImagesWithoutRebuildingViews() {
        let stack = ImageStackView(frame: .zero)
        let placeholders = [
            NSImage(size: NSSize(width: 100, height: 150)),
            NSImage(size: NSSize(width: 100, height: 150)),
            NSImage(size: NSSize(width: 100, height: 150))
        ]
        stack.setImages(placeholders, axis: .vertical)

        // Snapshot the existing layer/subview frames as proof of identity.
        let originalFrames = (0..<3).compactMap { stack.frame(forPageAt: $0) }
        #expect(originalFrames.count == 3)

        // Replace middle image. Same count, same axis → incremental path.
        let real = NSImage(size: NSSize(width: 100, height: 150))
        let updated = [placeholders[0], real, placeholders[2]]
        stack.setImages(updated, axis: .vertical)

        // Frames must be unchanged — no rebuild happened.
        let newFrames = (0..<3).compactMap { stack.frame(forPageAt: $0) }
        #expect(newFrames == originalFrames)
    }

    @Test func pageIndexRangeCoversAllVisibleSlots() {
        let stack = ImageStackView(frame: .zero)
        let images = (0..<5).map { _ in NSImage(size: NSSize(width: 1000, height: 1500)) }
        stack.setImages(images, axis: .vertical)
        // Layout: image i ∈ [i*1500, (i+1)*1500)

        // A viewport from y=2500 (image 1) to y=4800 (image 3) should yield 1..<4
        let rect = NSRect(x: 0, y: 2500, width: 1000, height: 2300)
        let range = stack.pageIndexRange(visibleIn: rect)
        #expect(range == 1..<4)
    }

    @Test func pageIndexRangeAtTopReturnsLeadingPages() {
        let stack = ImageStackView(frame: .zero)
        let images = (0..<5).map { _ in NSImage(size: NSSize(width: 1000, height: 1500)) }
        stack.setImages(images, axis: .vertical)

        // Viewport at top showing image 0 fully + part of image 1
        let rect = NSRect(x: 0, y: 0, width: 1000, height: 1800)
        let range = stack.pageIndexRange(visibleIn: rect)
        #expect(range == 0..<2)
    }

    @Test func pageIndexRangeIsEmptyForEmptyStack() {
        let stack = ImageStackView(frame: .zero)
        stack.setImages([], axis: .vertical)
        let range = stack.pageIndexRange(visibleIn: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(range == 0..<0)
    }

    @Test func axisChangeForcesFullRebuild() {
        let stack = ImageStackView(frame: .zero)
        let images = [
            NSImage(size: NSSize(width: 100, height: 150)),
            NSImage(size: NSSize(width: 100, height: 150))
        ]
        stack.setImages(images, axis: .vertical)
        let verticalSecond = stack.frame(forPageAt: 1)
        // Vertical: image 1 sits below image 0 → (0, 150, 100, 150)
        #expect(verticalSecond?.origin.y == 150)
        #expect(verticalSecond?.origin.x == 0)

        stack.setImages(images, axis: .horizontal)
        let horizontalSecond = stack.frame(forPageAt: 1)
        // Horizontal: image 1 sits to the right of image 0 → (100, 0, 100, 150)
        #expect(horizontalSecond?.origin.x == 100)
        #expect(horizontalSecond?.origin.y == 0)
    }
}
