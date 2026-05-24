import Foundation

nonisolated protocol SecurityScopedBookmarking: Sendable {
    func data(for url: URL) throws -> Data
    func resolve(_ bookmarkData: Data) -> SecurityScopedBookmark.Resolution?
    func refreshedData(for url: URL) -> Data?
    func isDirectory(_ url: URL) -> Bool
}

nonisolated struct LiveSecurityScopedBookmarkResolver: SecurityScopedBookmarking {
    func data(for url: URL) throws -> Data {
        try SecurityScopedBookmark.data(for: url)
    }

    func resolve(_ bookmarkData: Data) -> SecurityScopedBookmark.Resolution? {
        SecurityScopedBookmark.resolve(bookmarkData)
    }

    func refreshedData(for url: URL) -> Data? {
        SecurityScopedBookmark.refreshedData(for: url)
    }

    func isDirectory(_ url: URL) -> Bool {
        SecurityScopedBookmark.isDirectory(url)
    }
}

nonisolated enum SecurityScopedBookmark {
    struct Resolution: Sendable {
        let url: URL
        let isStale: Bool
    }

    static func data(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ bookmarkData: Data) -> Resolution? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return Resolution(url: url, isStale: isStale)
    }

    static func refreshedData(for url: URL) -> Data? {
        try? data(for: url)
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
