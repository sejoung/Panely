import AppKit
import SwiftUI
import Testing
@testable import Panely

/// Reading back what a hosted view actually drew, for the rendering tests
/// that mutate a view model and check the screen followed (sidebar rows,
/// toolbar controls, the edit bar, thumbnails).
///
/// Structure first: AppKit-backed pieces (the `List`'s `NSOutlineView`, the
/// focus-ring view SwiftUI adds per control) say what exists and where.
/// Pixels only where nothing else can tell — a row's accent highlight, a
/// badge, a dimmed (disabled) glyph — and then as counts in a region, not
/// comparisons with a picture. (SwiftUI builds no accessibility tree until
/// an accessibility client asks, so labels and traits aren't available.)
@MainActor
extension SnapshotRenderer.HostedView {
    /// Every view in the hosted hierarchy, depth-first.
    func allSubviews() -> [NSView] {
        func walk(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(walk)
        }
        return walk(hostingView)
    }

    /// Frames of the controls on screen (`Button`s, `Menu`s, fields), top to
    /// bottom, left to right, in the hosted view's points from the top left.
    ///
    /// SwiftUI gives every control an AppKit `_FocusRingView` to draw its
    /// focus ring in — the closest thing to a control tree AppKit has
    /// without an accessibility client attached. (It also adds a
    /// `KeyViewProxy` per enabled control, but doesn't add one when a
    /// disabled control becomes enabled, so that can't tell enabled state;
    /// read the glyph's brightness instead.) If a macOS update renames the
    /// class, this finds no controls and the tests using it fail loudly.
    func controlFrames() -> [CGRect] {
        var seen = Set<String>()
        return allSubviews()
            .filter { String(describing: type(of: $0)) == "_FocusRingView" && !$0.isHiddenOrHasHiddenAncestor }
            .map { frameInHost(of: $0, rect: $0.bounds).integral }
            .filter { seen.insert("\($0)").inserted }
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// `rect` in `view`'s coordinates, as hosted-view points from the top left.
    func frameInHost(of view: NSView, rect: CGRect) -> CGRect {
        let converted = view.convert(rect, to: hostingView)
        guard !hostingView.isFlipped else { return converted }
        return CGRect(
            x: converted.minX,
            y: hostingView.bounds.height - converted.maxY,
            width: converted.width,
            height: converted.height
        )
    }

    /// What's drawn right now.
    func capture() throws -> RenderedPixels {
        hostingView.layoutSubtreeIfNeeded()
        guard let pixels = RenderedPixels(png: try pngData(), pointSize: size) else {
            throw SnapshotRenderer.RenderError.encodingFailed
        }
        return pixels
    }

    /// Polls until `condition` holds, laying the view out between tries —
    /// SwiftUI applies a model change on a later run-loop pass, and the
    /// sidebar's tree loads asynchronously. On timeout, records `describe()`
    /// (what did render) and throws.
    func settle(
        _ expectation: String,
        timeout: Duration = .seconds(10),
        describe: () throws -> String = { "" },
        until condition: () throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            hostingView.layoutSubtreeIfNeeded()
            if try condition() { return }
            if clock.now >= deadline {
                Issue.record("Timed out waiting for: \(expectation)\n\(try describe())")
                throw SettleTimeout()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    struct SettleTimeout: Error {}
}

/// A capture's pixels, 8-bit sRGB RGBA, addressed in points from the top
/// left (the capture is at `SnapshotRenderer.renderScale`).
struct RenderedPixels {
    let width: Int
    let height: Int
    let scale: CGFloat
    private let bytes: [UInt8]

    struct RGB: Equatable {
        let r: Int
        let g: Int
        let b: Int

        /// `PanelyColor.accentPrimary` (#0A84FF) and its anti-aliased edges
        /// over the dark chrome — what highlights, active toggles and
        /// progress rings are drawn in. Nothing else in the chrome is blue.
        var isAccent: Bool {
            b >= 150 && b - r >= 110 && b - g >= 50 && g - r >= 30
        }

        func differs(from other: RGB, by tolerance: Int) -> Bool {
            abs(r - other.r) > tolerance || abs(g - other.g) > tolerance || abs(b - other.b) > tolerance
        }
    }

    init?(png: Data, pointSize: CGSize) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        width = image.width
        height = image.height
        scale = CGFloat(image.width) / max(pointSize.width, 1)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        bytes = buffer
    }

    /// The pixel at a point (top-left origin).
    func color(at point: CGPoint) -> RGB {
        let x = min(max(Int(point.x * scale), 0), width - 1)
        let y = min(max(Int(point.y * scale), 0), height - 1)
        // A bitmap context's first row in memory is the image's top row.
        let offset = (y * width + x) * 4
        return RGB(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]))
    }

    /// Pixels in `rect` (points, top-left origin) that satisfy `test`.
    func count(in rect: CGRect, where test: (RGB) -> Bool) -> Int {
        let minX = max(Int((rect.minX * scale).rounded(.down)), 0)
        let maxX = min(Int((rect.maxX * scale).rounded(.up)), width)
        let minY = max(Int((rect.minY * scale).rounded(.down)), 0)
        let maxY = min(Int((rect.maxY * scale).rounded(.up)), height)
        guard minX < maxX, minY < maxY else { return 0 }
        var matches = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = (y * width + x) * 4
                if test(RGB(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]))) {
                    matches += 1
                }
            }
        }
        return matches
    }

    func accentPixels(in rect: CGRect) -> Int {
        count(in: rect) { $0.isAccent }
    }

    /// Near-white pixels: an enabled control's glyph or label. A disabled
    /// one is drawn dimmed and has none.
    func brightPixels(in rect: CGRect) -> Int {
        count(in: rect) { min($0.r, $0.g, $0.b) >= 200 }
    }

    /// Pixels in `rect` that differ from `background` — anything drawn there.
    func inkPixels(in rect: CGRect, over background: RGB, tolerance: Int = 40) -> Int {
        count(in: rect) { $0.differs(from: background, by: tolerance) }
    }
}
