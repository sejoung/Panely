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
        // Thumbnails are small (~112 × 160 px × 4 channels × 2× retina ≈ 144 KB
        // worst-case), so we can keep plenty of them around for smooth scroll
        // in the sidebar. NSCache still evicts under memory pressure.
        cache.countLimit = 400
        return cache
    }()

    private init() {}

    func thumbnail(for page: ComicPage, maxPixelSize: CGFloat = 240) async -> NSImage? {
        let key = "\(page.id.uuidString)@\(Int(maxPixelSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        do {
            let image = try await Self.generate(for: page, maxPixelSize: maxPixelSize)
            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }

    nonisolated private static func generate(
        for page: ComicPage,
        maxPixelSize: CGFloat
    ) async throws -> NSImage {
        switch page.source {
        case .file(let url):
            return try await Task.detached(priority: .userInitiated) {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    throw ThumbnailLoaderError.decodingFailed
                }
                return try makeThumbnail(from: src, maxPixelSize: maxPixelSize)
            }.value

        case .archiveEntry(let reader, let path):
            // Archive entries need the raw bytes first. Reader is an actor so
            // the fetch is serialised; ZIPFoundation does the decompression.
            let data = try await reader.loadData(at: path)
            return try await Task.detached(priority: .userInitiated) {
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
                    throw ThumbnailLoaderError.decodingFailed
                }
                return try makeThumbnail(from: src, maxPixelSize: maxPixelSize)
            }.value
        }
    }

    /// Relies on Image I/O's built-in thumbnail path. Critically,
    /// `kCGImageSourceCreateThumbnailFromImageAlways = true` forces generation
    /// even when the source has no embedded thumbnail. Retina-aware by
    /// multiplying `maxPixelSize` by 2 so 1× display doesn't look soft.
    nonisolated private static func makeThumbnail(
        from src: CGImageSource,
        maxPixelSize: CGFloat
    ) throws -> NSImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize * 2
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw ThumbnailLoaderError.decodingFailed
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
