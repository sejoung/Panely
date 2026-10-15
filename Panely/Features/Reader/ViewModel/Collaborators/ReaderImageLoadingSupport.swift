import AppKit
import Foundation

@MainActor
final class ReaderImageMemoryCache {
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 100
        cache.totalCostLimit = ReaderImageMemoryCache.costLimit()
        return cache
    }()

    static let minCostLimit: UInt64 = 150 * 1024 * 1024
    static let maxCostLimit: UInt64 = 1024 * 1024 * 1024

    /// Image-memory budget scaled to the host's RAM. A fixed cap thrashed on
    /// high-res scan series (a single 2000×3000 page ≈ 24 MB, so a 150 MB cap
    /// held only ~6 pages — tighter than preload + spread want), while a
    /// large fixed cap would over-commit on small machines. ~1/16 of physical
    /// memory, clamped to [150 MB, 1 GB].
    static func costLimit() -> Int {
        costLimit(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    /// Pure clamp policy, split out so the boundaries are unit-testable
    /// without depending on the host's actual RAM.
    static func costLimit(physicalMemory: UInt64) -> Int {
        let target = physicalMemory / 16
        let clamped = min(max(target, minCostLimit), maxCostLimit)
        return Int(clamped)
    }

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

    /// Loaded pages to drop back to placeholders for `range`: every page
    /// outside `keepRange`, plus — when the pages left inside it still cost
    /// more than `byteBudget` — the ones farthest from the viewport until the
    /// rest fits. A count-only window held visible + 20 full-res bitmaps
    /// whatever their size; on tall webtoon slices that is gigabytes.
    ///
    /// Pages within `visibleRangeBuffer` of `range` are never evicted, even
    /// over budget: they're exactly what `loadIndices` re-requests, so
    /// evicting them would decode them again on the next scroll tick.
    func evictionIndices(
        forVisibleRange range: Range<Int>,
        loaded: Set<Int>,
        loadedImageCount: Int,
        byteBudget: Int,
        cost: (Int) -> Int
    ) -> [Int] {
        guard !range.isEmpty else { return [] }
        let keep = keepRange(forVisibleRange: range, loadedImageCount: loadedImageCount)
        var evicted = loaded.filter { !keep.contains($0) }
        let kept = loaded.subtracting(evicted)

        var total = kept.reduce(0) { $0 + cost($1) }
        if total > byteBudget {
            let buffer = ReaderImageLoadingPolicy.visibleRangeBuffer
            let protected = (range.lowerBound - buffer)..<(range.upperBound + buffer)
            func distance(_ i: Int) -> Int {
                i < range.lowerBound ? range.lowerBound - i : i - (range.upperBound - 1)
            }
            let candidates = kept
                .filter { !protected.contains($0) }
                .sorted { (distance($0), $0) > (distance($1), $1) }
            for i in candidates where total > byteBudget {
                evicted.insert(i)
                total -= cost(i)
            }
        }
        return evicted.sorted()
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

    static func makeError(size: CGSize, title: String) -> NSImage {
        let safeSize = CGSize(width: max(size.width, 320), height: max(size.height, 240))
        return NSImage(size: safeSize, flipped: false) { rect in
            NSColor(white: 0.10, alpha: 1).setFill()
            rect.fill()

            let border = NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2))
            NSColor.systemRed.withAlphaComponent(0.65).setStroke()
            border.lineWidth = 4
            border.stroke()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: min(42, max(18, safeSize.width / 18)), weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
                .paragraphStyle: paragraph,
            ]
            let text = String(localized: "Failed to load\n\(title)", bundle: .localized)
            let textRect = rect.insetBy(dx: 32, dy: max(32, rect.height * 0.35))
            text.draw(in: textRect, withAttributes: attributes)
            return true
        }
    }
}
