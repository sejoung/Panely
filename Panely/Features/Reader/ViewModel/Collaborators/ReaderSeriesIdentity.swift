import Foundation

/// Stable identifier for the *series* a book belongs to — the unit across
/// which per-series reader state is shared (session zoom carry-over, and the
/// persisted direction/layout/fitMode memory).
///
/// Mirrors `PositionKey`'s source resolution but groups at the **series**
/// level rather than the individual book:
/// - A book opened from inside an archive (zip-in-zip, extracted under the
///   temp root) → the opened archive itself. All inner volumes of one archive
///   form a single series, and the key stays stable across sessions even
///   though the extraction directory does not.
/// - A normal file or a folder-listed archive → its parent directory. Volumes
///   sitting side-by-side in a folder form a series (the same definition
///   `FolderResolver.scanSiblings` uses for prev/next-volume navigation).
///
/// Returns `nil` when there is no source (nothing open), or for a standalone
/// book with no meaningful container — callers treat `nil` as "no series
/// scope" and fall back to global behavior.
nonisolated enum ReaderSeriesIdentity {
    static func make(
        for sourceURL: URL?,
        opened openedURL: URL?,
        tempRoot tempDir: URL?
    ) -> String? {
        guard let sourceURL else { return nil }

        // Inside an extracted archive → series == the opened archive.
        if let openedURL,
           let tempDir,
           tempDir.relativeSubpath(to: sourceURL) != nil {
            return "series:" + openedURL.standardizedFileURL.path
        }

        // Normal file / folder-listed archive → series == parent directory.
        return "series:" + sourceURL.deletingLastPathComponent().standardizedFileURL.path
    }
}
