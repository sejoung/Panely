import AppKit
import Foundation

@MainActor
final class ReaderImageMemoryCache {
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()

    func image(for page: ComicPage) -> NSImage? {
        cache.object(forKey: page.id as NSString)
    }

    func store(_ image: NSImage, for page: ComicPage) {
        cache.setObject(image, forKey: page.id as NSString, cost: Self.estimatedBitmapCost(of: image))
    }

    static func estimatedBitmapCost(of image: NSImage) -> Int {
        if let rep = image.representations.first {
            let w = rep.pixelsWide
            let h = rep.pixelsHigh
            if w > 0 && h > 0 {
                let bitsPerSample = (rep as? NSBitmapImageRep)?.bitsPerSample ?? 8
                let samplesPerPixel = (rep as? NSBitmapImageRep)?.samplesPerPixel ?? 4
                let bytesPerPixel = max(1, (bitsPerSample * samplesPerPixel) / 8)
                return w * h * bytesPerPixel
            }
        }
        return Int(image.size.width * image.size.height * 4)
    }
}

nonisolated enum ReaderImageLoadingPolicy {
    static let preloadRadius = 2
    static let lazyWindowRadius = 3
    static let lazyKeepBuffer = 10
    static let visibleRangeBuffer = 2

    static var lazyConcurrencyLimit: Int {
        max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
    }
}

nonisolated struct ReaderVerticalImageWindow {
    let pageCount: Int

    func initialIndices(around index: Int, excluding loaded: Set<Int>) -> [Int] {
        guard pageCount > 0 else { return [] }
        let lower = max(0, index - ReaderImageLoadingPolicy.lazyWindowRadius)
        let upper = min(pageCount - 1, index + ReaderImageLoadingPolicy.lazyWindowRadius)
        guard lower <= upper else { return [] }
        return (lower...upper).filter { !loaded.contains($0) }
    }

    func loadIndices(forVisibleRange range: Range<Int>, excluding loaded: Set<Int>) -> [Int] {
        guard !range.isEmpty else { return [] }
        let lower = max(0, range.lowerBound - ReaderImageLoadingPolicy.visibleRangeBuffer)
        let upper = min(pageCount, range.upperBound + ReaderImageLoadingPolicy.visibleRangeBuffer)
        guard lower < upper else { return [] }
        return (lower..<upper).filter { !loaded.contains($0) }
    }

    func keepRange(forVisibleRange range: Range<Int>, loadedImageCount: Int) -> Range<Int> {
        let lower = max(0, range.lowerBound - ReaderImageLoadingPolicy.lazyKeepBuffer)
        let upper = min(loadedImageCount, range.upperBound + ReaderImageLoadingPolicy.lazyKeepBuffer)
        return lower..<max(lower, upper)
    }
}

nonisolated enum ReaderImagePlaceholder {
    static func make(size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.13, alpha: 1).setFill()
            rect.fill()
            return true
        }
    }
}
