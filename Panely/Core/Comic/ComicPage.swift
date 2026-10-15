import Foundation

nonisolated struct ComicPage: Identifiable, Sendable {
    /// Deterministic identifier derived from the page's source plus the
    /// source file's content signature. Stable while the file is unchanged,
    /// but changes when a file/archive is replaced in-place so image and
    /// thumbnail caches do not serve stale pages.
    let id: String
    let source: ComicPageSource
    let displayName: String

    /// `contentSignature`, when given, must be `contentSignature(for:)` of the
    /// source's file (the archive, for an entry). Every page of an archive
    /// shares one, so `ArchiveLoader` stats the archive once instead of once
    /// per page; `nil` computes it here.
    init(source: ComicPageSource, displayName: String, contentSignature: String? = nil) {
        self.id = Self.makeID(for: source, signature: contentSignature)
        self.source = source
        self.displayName = displayName
    }

    private static func makeID(for source: ComicPageSource, signature: String?) -> String {
        switch source {
        case .file(let url):
            return "file:" + url.standardizedFileURL.path + "#" + (signature ?? contentSignature(for: url))
        case .archiveEntry(let reader, let path):
            // ArchiveReader is identified by its archive URL — different
            // readers for the same archive must produce the same id so
            // caches survive an archive reopen. Include the archive's content
            // signature so replacing a file in-place invalidates image caches
            // while the reader is still open.
            return "archive:"
                + reader.archiveURL.standardizedFileURL.path
                + "#"
                + (signature ?? contentSignature(for: reader.archiveURL))
                + "#"
                + path
        }
    }

    /// Size + modification date of the file at `url`; part of every page id.
    static func contentSignature(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        return "\(size):\(modified)"
    }
}
