import Foundation

nonisolated protocol SecurityScopedBookmarking: Sendable {
    func data(for url: URL) throws -> Data
    func resolve(_ bookmarkData: Data) -> SecurityScopedBookmark.Resolution?
    func refreshedData(for url: URL) -> Data?
    func isDirectory(_ url: URL) -> Bool
}

extension SecurityScopedBookmarking {
    /// Resolve `data` and, when the OS reports the bookmark stale, mint a fresh
    /// one in place. Returns the resolved `url` plus, when a refresh happened,
    /// the new bookmark data and standardized path for the caller to persist.
    /// Returns `nil` only when the bookmark can't be resolved at all.
    ///
    /// Shared by `FavoritesStore` and `RecentItemsStore`, whose `resolve`
    /// methods were otherwise byte-for-byte identical.
    func resolveRefreshing(_ data: Data) -> (url: URL, refreshed: (data: Data, path: String)?)? {
        guard let resolution = resolve(data) else { return nil }
        let url = resolution.url
        guard resolution.isStale, let newData = refreshedData(for: url) else {
            return (url, nil)
        }
        return (url, (newData, url.standardizedFileURL.path))
    }
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
        // Creating a `.withSecurityScope` bookmark requires the URL to have
        // active security-scoped access. Callers resolve stale bookmarks
        // before the library scope is acquired, so bracket access here —
        // otherwise `data(for:)` silently fails and the stale bookmark is
        // never refreshed.
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try? data(for: url)
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
