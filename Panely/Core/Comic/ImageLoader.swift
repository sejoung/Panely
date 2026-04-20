import AppKit
import ImageIO

enum ImageLoaderError: Error {
    case decodingFailed
}

nonisolated enum ImageLoader {
    static func load(_ page: ComicPage) async throws -> NSImage {
        let data = try await loadData(for: page.source)
        return try await decode(data)
    }

    /// Reads only the image header to recover pixel dimensions — fast enough
    /// (microseconds for file URLs) to call for hundreds of pages on entry.
    /// For archive entries the full entry data still has to be read because
    /// ZIPFoundation doesn't expose partial reads, but no decode is performed.
    static func dimensions(for page: ComicPage) async throws -> CGSize {
        switch page.source {
        case .file(let url):
            return try await Task.detached(priority: .userInitiated) {
                try Self.readDimensionsFromURL(url)
            }.value

        case .archiveEntry(let reader, let path):
            let data = try await reader.loadData(at: path)
            return try await Task.detached(priority: .userInitiated) {
                try Self.readDimensionsFromData(data)
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
