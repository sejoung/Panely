import AppKit
import ImageIO

enum ImageLoaderError: Error {
    case decodingFailed
}

nonisolated enum ImageLoader {
    /// Loads and *eagerly* decodes the image on a background queue. The
    /// previous `NSImage(data:)` path was lazy — decode happened on first
    /// draw, typically on the main thread, causing visible hitches when
    /// paging. `kCGImageSourceShouldCacheImmediately` forces ImageIO to
    /// produce a fully-decoded `CGImage` here, off the main thread, so the
    /// NSImage we return is render-ready.
    ///
    /// File URLs go straight through `CGImageSourceCreateWithURL` (zero-copy
    /// mmap by ImageIO). Archive entries still need to materialize bytes via
    /// the `ArchiveReader` actor before they can be decoded.
    static func load(_ page: ComicPage) async throws -> NSImage {
        switch page.source {
        case .file(let url):
            return try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    throw ImageLoaderError.decodingFailed
                }
                return try Self.decodeEagerly(from: src)
            }.value

        case .archiveEntry(let reader, let path):
            let data = try await reader.loadData(at: path)
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
                    throw ImageLoaderError.decodingFailed
                }
                return try Self.decodeEagerly(from: src)
            }.value
        }
    }

    /// Pulls a fully-decoded `CGImage` and wraps it in `NSImage`. The
    /// `kCGImageSourceShouldCacheImmediately` option is the lever — without
    /// it, the returned CGImage backs onto a deferred decoder and the work
    /// gets paid by the main thread on first draw.
    private static func decodeEagerly(from src: CGImageSource) throws -> NSImage {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else {
            throw ImageLoaderError.decodingFailed
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Reads only the image header to recover pixel dimensions — fast enough
    /// (microseconds for file URLs) to call for hundreds of pages on entry.
    /// For archive entries we now also short-circuit at ~64 KB via
    /// `ArchiveReader.loadDataPrefix`; PNG dimensions live in the first ~33
    /// bytes, JPEG SOF markers within the first few KB after EXIF. Falls
    /// back to a full entry read only if the prefix can't yield dimensions
    /// (e.g., unusually large EXIF blocks that push SOF past the prefix).
    static func dimensions(for page: ComicPage) async throws -> CGSize {
        switch page.source {
        case .file(let url):
            return try await Task.detached(priority: .userInitiated) {
                try Self.readDimensionsFromURL(url)
            }.value

        case .archiveEntry(let reader, let path):
            let prefix = try await reader.loadDataPrefix(at: path, maxBytes: 64 * 1024)
            if let size = try? await Task.detached(priority: .userInitiated, operation: {
                try Self.readDimensionsFromData(prefix)
            }).value {
                return size
            }
            // Fallback: prefix wasn't enough. Read the entire entry.
            let full = try await reader.loadData(at: path)
            return try await Task.detached(priority: .userInitiated) {
                try Self.readDimensionsFromData(full)
            }.value
        }
    }

    private static func readDimensionsFromURL(_ url: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoaderError.decodingFailed
        }
        return try extractDimensions(from: source)
    }

    private static func readDimensionsFromData(_ data: Data) throws -> CGSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageLoaderError.decodingFailed
        }
        return try extractDimensions(from: source)
    }

    private static func extractDimensions(from source: CGImageSource) throws -> CGSize {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else {
            throw ImageLoaderError.decodingFailed
        }
        return CGSize(width: width, height: height)
    }
}
