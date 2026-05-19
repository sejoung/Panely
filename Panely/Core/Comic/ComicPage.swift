import Foundation

nonisolated struct ComicPage: Identifiable, Sendable {
    /// Deterministic identifier derived from the page's source. Stable
    /// across `ComicSource` reloads of the same book, so the image and
    /// thumbnail caches stay warm when a user closes and re-opens a
    /// volume. Was a random `UUID()` previously — every reload caused a
    /// full thumbnail re-decode.
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
            return "file:" + url.standardizedFileURL.path
        case .archiveEntry(let reader, let path):
            // ArchiveReader is identified by its archive URL — different
            // readers for the same archive must produce the same id so
            // caches survive an archive reopen.
            return "archive:" + reader.archiveURL.standardizedFileURL.path + "#" + path
        }
    }
}
