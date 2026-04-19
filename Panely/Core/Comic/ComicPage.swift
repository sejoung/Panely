import Foundation

nonisolated struct ComicPage: Identifiable, Sendable {
    let id: UUID
    let source: ComicPageSource
    let displayName: String

    init(source: ComicPageSource, displayName: String) {
        self.id = UUID()
        self.source = source
        self.displayName = displayName
    }
}
