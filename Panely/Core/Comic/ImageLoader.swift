import AppKit

enum ImageLoaderError: Error {
    case decodingFailed
}

nonisolated enum ImageLoader {
    static func load(_ page: ComicPage) async throws -> NSImage {
        let data = try await loadData(for: page.source)
        return try await decode(data)
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
}
