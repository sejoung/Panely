import Foundation

nonisolated struct AppDependencies: Sendable {
    var extractionCache: any ExtractionCacheManaging
    var bookmarkResolver: any SecurityScopedBookmarking
    var libraryTreeLoader: any LibraryTreeLoading

    static let live = AppDependencies(
        extractionCache: LiveExtractionCacheManager(),
        bookmarkResolver: LiveSecurityScopedBookmarkResolver(),
        libraryTreeLoader: LiveLibraryTreeLoader()
    )
}
