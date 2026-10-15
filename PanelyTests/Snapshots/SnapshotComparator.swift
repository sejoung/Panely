import AppKit
import CoreGraphics
import Foundation

/// Compares a rendered PNG with a reference PNG pixel by pixel, tolerating
/// the anti-aliasing and font-smoothing noise that differs between runs and
/// machines but not a layout change.
///
/// Calibration: re-rendering the same screen on another day differed in
/// about 0.01% of pixels (sidebar, 480×1440 px), and re-recording every
/// reference on one machine reproduces them byte for byte. Breakages that
/// must fail: the file tree drawn flat (fixed in e344e1b) — 4.3% of the
/// sidebar, 0.34% of a reader screen with it; the toolbar's language menu
/// gone — 0.41% of the toolbar; a popover button's label gone — 0.27%; a
/// form row gone — 5%.
///
/// The chrome is dark on dark: a form row's fill is ~7 levels off the
/// window's, a bordered button's ~20. A 24-level tolerance with a 0.5%
/// budget (the first calibration) let a whole missing settings row and
/// every one of those small breakages through; 6 levels and 0.1% catch them
/// all and still leave 10× the measured noise.
nonisolated enum SnapshotComparator {
    /// A channel difference at or below this counts as the same pixel.
    static let channelTolerance: UInt8 = 6
    /// Share of pixels allowed to differ beyond `channelTolerance`.
    static let defaultMaxDifferingFraction = 0.001

    struct Result {
        let width: Int
        let height: Int
        let differingPixels: Int
        /// Pixels left out of the comparison (`ignoring`).
        var maskedPixels = 0
        /// The actual image dimmed, with differing pixels in red and
        /// ignored regions in blue.
        let diffPNG: Data?

        var comparedPixels: Int { width * height - maskedPixels }

        var differingFraction: Double {
            Double(differingPixels) / Double(max(comparedPixels, 1))
        }
    }

    enum ComparisonError: Error, CustomStringConvertible {
        case undecodable(String)
        case sizeMismatch(actual: CGSize, reference: CGSize)

        var description: String {
            switch self {
            case .undecodable(let which):
                return "Couldn't decode the \(which) PNG"
            case .sizeMismatch(let actual, let reference):
                return "Size changed: rendered \(Int(actual.width))×\(Int(actual.height)) px, reference \(Int(reference.width))×\(Int(reference.height)) px"
            }
        }
    }

    /// `ignoring`: regions, in pixels from the top left, whose content
    /// depends on the machine rather than the layout (a locale-formatted
    /// number, say). They don't count either way.
    static func compare(
        actual actualPNG: Data,
        reference referencePNG: Data,
        ignoring masks: [CGRect] = []
    ) throws -> Result {
        guard let actual = RGBAImage(png: actualPNG) else { throw ComparisonError.undecodable("rendered") }
        guard let reference = RGBAImage(png: referencePNG) else { throw ComparisonError.undecodable("reference") }
        guard actual.width == reference.width, actual.height == reference.height else {
            throw ComparisonError.sizeMismatch(
                actual: CGSize(width: actual.width, height: actual.height),
                reference: CGSize(width: reference.width, height: reference.height)
            )
        }

        let width = actual.width
        let height = actual.height
        var diff = [UInt8](repeating: 0, count: actual.pixels.count)
        var differing = 0
        var masked = 0
        // Unsafe buffers: the test target builds unoptimized, where bounds-
        // checked indexing over a few million pixels takes seconds.
        actual.pixels.withUnsafeBufferPointer { a in
            reference.pixels.withUnsafeBufferPointer { b in
                diff.withUnsafeMutableBufferPointer { d in
                    let tolerance = Int(channelTolerance)
                    for y in 0..<height {
                        let rowMasks = masks.filter { CGFloat(y) >= $0.minY && CGFloat(y) < $0.maxY }
                        for x in 0..<width {
                            let offset = (y * width + x) * 4
                            d[offset + 3] = 255
                            if !rowMasks.isEmpty, rowMasks.contains(where: { CGFloat(x) >= $0.minX && CGFloat(x) < $0.maxX }) {
                                masked += 1
                                d[offset + 2] = 160
                                continue
                            }
                            let r = Int(a[offset]), g = Int(a[offset + 1]), bl = Int(a[offset + 2])
                            if abs(r - Int(b[offset])) > tolerance
                                || abs(g - Int(b[offset + 1])) > tolerance
                                || abs(bl - Int(b[offset + 2])) > tolerance {
                                differing += 1
                                d[offset] = 255
                            } else {
                                let gray = UInt8((r + g + bl) / 9)
                                d[offset] = gray
                                d[offset + 1] = gray
                                d[offset + 2] = gray
                            }
                        }
                    }
                }
            }
        }

        return Result(
            width: actual.width,
            height: actual.height,
            differingPixels: differing,
            maskedPixels: masked,
            diffPNG: differing == 0 ? nil : RGBAImage(width: actual.width, height: actual.height, pixels: diff).png()
        )
    }

    /// 8-bit sRGB RGBA pixels, so two PNGs compare byte for byte whatever
    /// color space or alpha layout each was encoded with.
    private struct RGBAImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        init?(png: Data) {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            width = image.width
            height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(
                    data: bytes.baseAddress,
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
            pixels = buffer
        }

        func png() -> Data? {
            var bytes = pixels
            return bytes.withUnsafeMutableBytes { raw -> Data? in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ), let image = context.makeImage() else { return nil }
                return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
        }
    }
}
