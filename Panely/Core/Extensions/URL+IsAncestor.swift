import Foundation

extension URL {
    /// True when `candidate` lives at this URL or under it in the file
    /// hierarchy. Path-component aware — `"/a/series".isAncestor(of: "/a/series-extras/book.cbz")`
    /// is false because the boundary check requires a `/` after the root.
    /// Both URLs are standardized first so callers don't have to pre-normalize
    /// paths with redundant `.` / `//` components.
    ///
    /// Used by `ReaderLibraryScope` and `ReaderTempDirectory` to decide
    /// whether a clicked book lives inside the active library root / extraction
    /// dir respectively.
    nonisolated func isAncestor(of candidate: URL) -> Bool {
        relativeSubpath(to: candidate) != nil
    }

    /// The path of `descendant` relative to this URL, or `nil` when
    /// `descendant` is neither equal to nor under this URL. Returns `""` when
    /// the two are equal. Shares the `/`-boundary rule with `isAncestor(of:)`
    /// and standardizes both sides first, so callers don't reimplement the
    /// `hasPrefix(root + "/")` + `dropFirst(root.count + 1)` dance by hand.
    ///
    /// Named `relativeSubpath` (not `relativePath`) to avoid shadowing
    /// Foundation's `URL.relativePath` property.
    nonisolated func relativeSubpath(to descendant: URL) -> String? {
        let rootPath = standardizedFileURL.path
        let target = descendant.standardizedFileURL.path
        if target == rootPath { return "" }
        guard target.hasPrefix(rootPath + "/") else { return nil }
        return String(target.dropFirst(rootPath.count + 1))
    }
}
