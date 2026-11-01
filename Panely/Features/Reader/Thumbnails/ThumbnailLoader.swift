import AppKit
import ImageIO

enum ThumbnailLoaderError: Error {
    case decodingFailed
}

/// Generates downscaled NSImage thumbnails for `ComicPage`s and caches them
/// in an `NSCache`. Uses `CGImageSourceCreateThumbnailAtIndex` so we don't
/// pay the cost of decoding the full-resolution image just to shrink it.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // A portrait page's thumbnail is about 224 × 336 px × 4 channels ≈
        // 300 KB, so the byte cap below holds about 200 of them. NSCache still
        // evicts under memory pressure.
        cache.countLimit = 400
        // Cap total bytes at ~60 MB so a book with very tall pages can't blow
        // past a reasonable working-set size. `setObject(_:forKey:cost:)`
        // feeds per-entry estimates into this limit.
        cache.totalCostLimit = 60 * 1024 * 1024
        return cache
    }()

    private init() {}

    func removeAll() {
        cache.removeAllObjects()
    }

    /// Long-side cap in points: `ThumbnailSidebar` clamps a cell to 3:1, so a
    /// taller page gains nothing from more pixels.
    func thumbnail(for page: ComicPage, maxPixelSize: CGFloat = 336) async -> NSImage? {
        let key = "\(page.id)@\(Int(maxPixelSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        do {
            let image = try await Self.generate(for: page, maxPixelSize: maxPixelSize)
            // Estimate decoded byte cost so `totalCostLimit` is honoured. The
            // NSImage size is in points; multiply by ~4× to approximate the
            // backing bitmap area. A rough figure is fine — NSCache treats it
            // as a hint, not a strict budget.
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: key, cost: cost)
            return image
        } catch {
            return nil
        }
    }

    nonisolated private static func generate(
        for page: ComicPage,
        maxPixelSize: CGFloat
    ) async throws -> NSImage {
        // `ImageLoader.detached` forwards cancellation, so a cell scrolled out
        // of view before its turn doesn't cost a decode. Below the viewer's
        // priority: the page being read comes before the sidebar.
        switch page.source {
        case .file(let url):
            return try await ImageLoader.detached(priority: .utility) {
                let data: Data
                do {
                    data = try Data(contentsOf: url, options: [.mappedIfSafe])
                } catch {
                    throw ThumbnailLoaderError.decodingFailed
                }
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
                    throw ThumbnailLoaderError.decodingFailed
                }
                return try makeThumbnail(from: src, maxPixelSize: maxPixelSize)
            }

        case .archiveEntry(let reader, let path):
            // Archive entries need the raw bytes first. Reader is an actor so
            // the fetch is serialised; the ZIP/RAR reader does the decompression.
            let data = try await reader.loadData(at: path)
            return try await ImageLoader.detached(priority: .utility) {
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
                    throw ThumbnailLoaderError.decodingFailed
                }
                return try makeThumbnail(from: src, maxPixelSize: maxPixelSize)
            }
        }
    }

    /// Pixels on the long side for a thumbnail that fills a cell's width at 2×.
    /// `CGImageSource` only takes a long-side limit, so a page's aspect decides
    /// it: one fixed value would be too big for portrait pages (the usual case)
    /// and too small for tall strips.
    nonisolated static func thumbnailLongSide(
        pixelSize: CGSize?,
        displayWidth: CGFloat = 112,
        maxPixelSize: CGFloat
    ) -> CGFloat {
        let cap = maxPixelSize * 2
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return min(cap, displayWidth * 2 * 1.5) // assume a 2:3 page
        }
        let tallness = max(1, pixelSize.height / pixelSize.width)
        return min(cap, (displayWidth * 2 * tallness).rounded(.up))
    }

    /// Relies on Image I/O's built-in thumbnail path. Critically,
    /// `kCGImageSourceCreateThumbnailFromImageAlways = true` forces generation
    /// even when the source has no embedded thumbnail.
    nonisolated private static func makeThumbnail(
        from src: CGImageSource,
        maxPixelSize: CGFloat
    ) throws -> NSImage {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let pixelSize = (props?[kCGImagePropertyPixelWidth] as? Int).flatMap { width in
            (props?[kCGImagePropertyPixelHeight] as? Int).map { CGSize(width: width, height: $0) }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailLongSide(pixelSize: pixelSize, maxPixelSize: maxPixelSize)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw ThumbnailLoaderError.decodingFailed
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
