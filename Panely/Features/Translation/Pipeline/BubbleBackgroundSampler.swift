import CoreGraphics
import Foundation

/// Samples the tone behind a balloon's text so the translation patch matches
/// it. Text covers a minority of a balloon, so the median-luminance pixel is
/// background; the sample averages every pixel close to it. How many pixels
/// are close says whether the area is one flat tone (balloon, caption box) or
/// artwork.
nonisolated enum BubbleBackgroundSampler {
    /// Max per-channel difference for a pixel to count as "background tone".
    static let tolerance: Double = 0.12
    /// Share of background-tone pixels above which the area counts as flat.
    static let uniformShare: Double = 0.6
    /// The rect is scaled down to at most this many pixels a side first.
    private static let sampleSide = 96

    static func sample(_ image: CGImage, in rect: CGRect) -> BubbleBackground {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1,
              let crop = image.cropping(to: clipped) else { return .white }

        let scale = min(1, Double(sampleSide) / Double(max(crop.width, crop.height)))
        let width = max(1, Int(Double(crop.width) * scale))
        let height = max(1, Int(Double(crop.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return .white }

        var samples: [(r: Double, g: Double, b: Double, l: Double)] = []
        samples.reserveCapacity(width * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255
            samples.append((r, g, b, 0.299 * r + 0.587 * g + 0.114 * b))
        }
        let median = samples.sorted { $0.l < $1.l }[samples.count / 2]
        let close = samples.filter {
            abs($0.r - median.r) <= tolerance
                && abs($0.g - median.g) <= tolerance
                && abs($0.b - median.b) <= tolerance
        }
        let count = Double(close.count)
        return BubbleBackground(
            red: close.reduce(0) { $0 + $1.r } / count,
            green: close.reduce(0) { $0 + $1.g } / count,
            blue: close.reduce(0) { $0 + $1.b } / count,
            isUniform: count / Double(samples.count) >= uniformShare
        )
    }
}
