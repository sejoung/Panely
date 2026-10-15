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
    ///
    /// Cancellation-aware: a cancelled caller skips the archive read and the
    /// decode (see `detached(_:)`). A decode already inside ImageIO can't be
    /// interrupted, so it finishes and its image is still returned — the
    /// caller may as well cache it.
    static func load(_ page: ComicPage) async throws -> NSImage {
        switch page.source {
        case .file(let url):
            return try await detached {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    throw ImageLoaderError.decodingFailed
                }
                return try Self.decodeEagerly(from: src)
            }

        case .archiveEntry(let reader, let path):
            try Task.checkCancellation()
            let data = try await reader.loadData(at: path)
            try Task.checkCancellation()
            return try await detached {
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
                    throw ImageLoaderError.decodingFailed
                }
                return try Self.decodeEagerly(from: src)
            }
        }
    }

    /// Runs `work` off the caller's actor at user-initiated priority.
    /// `Task.detached` doesn't inherit cancellation, so it's forwarded
    /// explicitly — otherwise a superseded page (slider scrub, fast paging)
    /// would still pay for a full decode. `work` starts with a cancellation
    /// check, so a task cancelled before it got a thread does no work.
    private static func detached<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try work()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
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
            return try await detached {
                try Self.readDimensionsFromURL(url)
            }

        case .archiveEntry(let reader, let path):
            let prefix = try await reader.loadDataPrefix(at: path, maxBytes: 64 * 1024)
            if let size = try? await detached({
                try Self.readDimensionsFromData(prefix)
            }) {
                return size
            }
            // Fallback: prefix wasn't enough. Read the entire entry.
            try Task.checkCancellation()
            let full = try await reader.loadData(at: path)
            return try await detached {
                try Self.readDimensionsFromData(full)
            }
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
