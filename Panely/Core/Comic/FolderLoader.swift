import Foundation

nonisolated enum FolderLoader {
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "bmp", "tiff", "tif"
    ]

    static func load(from url: URL) throws -> ComicSource {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            // Size + mtime come back with the listing, so building the page
            // ids doesn't need one `stat` per page — on a network volume that
            // is one round trip each.
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        let images = contents.filter { fileURL in
            supportedExtensions.contains(fileURL.pathExtension.lowercased())
        }

        let sorted = images.sorted(by: NaturalSort.byFilename)

        let pages = sorted.map { url in
            ComicPage(
                source: .file(url),
                displayName: url.lastPathComponent,
                contentSignature: prefetchedSignature(of: url)
            )
        }
        return ComicSource(title: url.lastPathComponent, pages: pages)
    }

    /// `nil` falls back to `ComicPage`'s own `stat`.
    private static func prefetchedSignature(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate
        else { return nil }
        return ComicPage.contentSignature(size: Int64(size), modified: modified.timeIntervalSince1970)
    }
}
