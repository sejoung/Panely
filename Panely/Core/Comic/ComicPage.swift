import Foundation

nonisolated struct ComicPage: Identifiable, Sendable {
    /// Deterministic identifier derived from the page's source plus the
    /// source file's content signature. Stable while the file is unchanged,
    /// but changes when a file/archive is replaced in-place so image and
    /// thumbnail caches do not serve stale pages.
    let id: String
    let source: ComicPageSource
    let displayName: String

    init(source: ComicPageSource, displayName: String) {
        self.id = Self.makeID(for: source)
        self.source = source
        self.displayName = displayName
    }

    private static func makeID(for source: ComicPageSource) -> String {
        switch source {
        case .file(let url):
            return "file:" + url.standardizedFileURL.path + "#" + contentSignature(for: url)
        case .archiveEntry(let reader, let path):
            // ArchiveReader is identified by its archive URL — different
            // readers for the same archive must produce the same id so
            // caches survive an archive reopen. Include the archive's content
            // signature so replacing a file in-place invalidates image caches
            // while the reader is still open.
            return "archive:"
                + reader.archiveURL.standardizedFileURL.path
                + "#"
                + contentSignature(for: reader.archiveURL)
                + "#"
                + path
        }
    }

    private static func contentSignature(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        return "\(size):\(modified)"
    }
}
