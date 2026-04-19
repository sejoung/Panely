import Foundation

nonisolated struct ComicSource: Sendable {
    let title: String
    let pages: [ComicPage]

    static let empty = ComicSource(title: "", pages: [])

    var isEmpty: Bool { pages.isEmpty }
    var pageCount: Int { pages.count }
}
