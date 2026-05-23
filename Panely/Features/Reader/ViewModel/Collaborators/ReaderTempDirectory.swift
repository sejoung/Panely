import Foundation

/// Lifecycle of the temp directory used to extract zip-in-zip archives. A
/// load that detects a nested archive creates a fresh `panely-<uuid>` dir
/// under the sandbox tmp, points the reader at it, and lets this type clean
/// it up on the next book switch or app launch.
///
/// Kept off `ReaderViewModel` so the load pipeline doesn't carry low-level
/// path comparison and orphan-sweep code alongside its own state.
@MainActor
final class ReaderTempDirectory {
    /// Currently active extraction root, or `nil` when the loaded source
    /// isn't a nested-archive case. Direct assignment is supported so tests
    /// can stage a fake temp root without going through extraction;
    /// production code should use `adopt(_:)` / `cleanup()`.
    var url: URL?

    /// True when the active source is being served out of an extracted temp
    /// directory.
    var isActive: Bool { url != nil }

    /// Mark `dir` as the active extraction root. Caller is responsible for
    /// having created it (typically via `Self.makeCandidate()`).
    func adopt(_ dir: URL) {
        url = dir
    }

    /// Remove the current temp dir from disk and clear the reference. Safe
    /// to call repeatedly — no-ops when nothing is active.
    func cleanup() {
        guard let dir = url else { return }
        try? FileManager.default.removeItem(at: dir)
        url = nil
    }

    /// True when `candidate` lives inside the active temp dir. False when
    /// no temp dir is active.
    func contains(_ candidate: URL) -> Bool {
        guard let temp = url else { return false }
        let tempPath = temp.standardizedFileURL.path
        let target = candidate.standardizedFileURL.path
        return target == tempPath || target.hasPrefix(tempPath + "/")
    }

    /// Generate a fresh candidate path under the sandbox tmp. Doesn't create
    /// the directory on disk — the loader does that via `CBZLoader.extractAll`.
    static func makeCandidate() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("panely-\(UUID().uuidString)", isDirectory: true)
    }

    /// Sweep `panely-*` directories left behind by a prior session that
    /// crashed or was force-quit before `cleanup()` could run. A single
    /// zip-in-zip extraction can be hundreds of megabytes, and macOS only
    /// sweeps the sandbox tmp opportunistically (not on every launch), so
    /// leftovers can quietly accumulate.
    ///
    /// Called from `ReaderViewModel.init` on a background queue, where it
    /// races with the app's own first extraction. To avoid deleting that
    /// brand-new dir, only sweep entries whose mtime is older than
    /// `staleAge` — anything fresher belongs to a concurrent load or
    /// another running instance.
    nonisolated static func cleanupStaleEntries() {
        let tmpRoot = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmpRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // 10 minutes is generous: even a multi-GB zip-in-zip extraction
        // typically finishes well under that, and anything older is almost
        // certainly orphaned from a prior session.
        let staleAge: TimeInterval = 10 * 60
        let cutoff = Date().addingTimeInterval(-staleAge)

        for entry in entries where entry.lastPathComponent.hasPrefix("panely-") {
            let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard mtime < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
