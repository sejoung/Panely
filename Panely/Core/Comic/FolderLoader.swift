import Foundation

nonisolated enum FolderLoader {
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "bmp", "tiff", "tif"
    ]

    static func load(from url: URL) throws -> ComicSource {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        let images = contents.filter { fileURL in
            supportedExtensions.contains(fileURL.pathExtension.lowercased())
        }

        let sorted = images.sorted { a, b in
            a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }

        let pages = sorted.map { url in
            ComicPage(source: .file(url), displayName: url.lastPathComponent)
        }
        return ComicSource(title: url.lastPathComponent, pages: pages)
    }
}
