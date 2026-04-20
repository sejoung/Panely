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
}
