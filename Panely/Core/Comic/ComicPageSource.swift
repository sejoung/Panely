import Foundation

nonisolated enum ComicPageSource: Sendable {
    case file(URL)
    case archiveEntry(reader: ArchiveReader, path: String)
}
