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
    func isAncestor(of candidate: URL) -> Bool {
        let rootPath = standardizedFileURL.path
        let target = candidate.standardizedFileURL.path
        return target == rootPath || target.hasPrefix(rootPath + "/")
    }
}
