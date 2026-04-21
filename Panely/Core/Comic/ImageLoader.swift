import AppKit
import ImageIO

enum ImageLoaderError: Error {
    case decodingFailed
}

nonisolated enum ImageLoader {
    static func load(_ page: ComicPage) async throws -> NSImage {
        let data = try await loadData(for: page.source)
        // Skip decode if the caller bailed while the data was being read —
        // saves a relatively expensive NSImage decode for stale work.
        try Task.checkCancellation()
        return try await decode(data)
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

    private static func loadData(for source: ComicPageSource) async throws -> Data {
        switch source {
        case .file(let url):
            return try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }.value

        case .archiveEntry(let reader, let path):
            return try await reader.loadData(at: path)
        }
    }

    private static func decode(_ data: Data) async throws -> NSImage {
        try await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(data: data) else {
                throw ImageLoaderError.decodingFailed
            }
            return image
        }.value
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
