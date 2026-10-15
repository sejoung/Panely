import Foundation

nonisolated protocol SecurityScopedBookmarking: Sendable {
    func data(for url: URL) throws -> Data
    func resolve(_ bookmarkData: Data) -> SecurityScopedBookmark.Resolution?
    /// `allowingMount: false` resolves without mounting the volume the
    /// bookmark lives on or showing any UI for it — for background sweeps
    /// and launch-time restores, where silently mounting a network share (or
    /// stalling the main thread on it) isn't what the user asked for. An
    /// unmounted target then simply fails to resolve.
    func resolve(_ bookmarkData: Data, allowingMount: Bool) -> SecurityScopedBookmark.Resolution?
    func refreshedData(for url: URL) -> Data?
    func isDirectory(_ url: URL) -> Bool
}

// `nonisolated`: the module defaults to MainActor isolation, which would
// otherwise pin these helpers to the main actor even though the protocol
// itself is nonisolated and they are called from background work.
nonisolated extension SecurityScopedBookmarking {
    /// Resolvers that never mount anything (test doubles) needn't tell the
    /// two resolutions apart.
    func resolve(_ bookmarkData: Data, allowingMount: Bool) -> SecurityScopedBookmark.Resolution? {
        resolve(bookmarkData)
    }

    /// Resolve `data` and, when the OS reports the bookmark stale, mint a fresh
    /// one in place. Returns the resolved `url` plus, when a refresh happened,
    /// the new bookmark data and standardized path for the caller to persist.
    /// Returns `nil` only when the bookmark can't be resolved at all.
    ///
    /// Shared by `FavoritesStore` and `RecentItemsStore`, whose `resolve`
    /// methods were otherwise byte-for-byte identical.
    func resolveRefreshing(
        _ data: Data,
        allowingMount: Bool = true
    ) -> (url: URL, refreshed: (data: Data, path: String)?)? {
        guard let resolution = resolve(data, allowingMount: allowingMount) else { return nil }
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

    func resolve(_ bookmarkData: Data, allowingMount: Bool) -> SecurityScopedBookmark.Resolution? {
        SecurityScopedBookmark.resolve(bookmarkData, allowingMount: allowingMount)
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

    static func resolve(_ bookmarkData: Data, allowingMount: Bool = true) -> Resolution? {
        var isStale = false
        let options: URL.BookmarkResolutionOptions = allowingMount
            ? .withSecurityScope
            : [.withSecurityScope, .withoutUI, .withoutMounting]
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: options,
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
