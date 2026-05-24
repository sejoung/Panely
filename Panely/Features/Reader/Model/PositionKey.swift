import Foundation

nonisolated enum PositionKey {
    struct Keys: Equatable {
        let primary: String
        let fileIdentity: String?
    }

    static func keys(
        for sourceURL: URL,
        opened openedURL: URL?,
        tempRoot tempDir: URL?
    ) -> Keys {
        Keys(
            primary: make(for: sourceURL, opened: openedURL, tempRoot: tempDir),
            fileIdentity: fileIdentityFallback(for: sourceURL, opened: openedURL, tempRoot: tempDir)
        )
    }

    static func make(
        for sourceURL: URL,
        opened openedURL: URL?,
        tempRoot tempDir: URL?
    ) -> String {
        let sourcePath = sourceURL.standardizedFileURL.path

        guard
            let opened = openedURL,
            let temp = tempDir
        else {
            return sourcePath
        }

        let tempPath = temp.standardizedFileURL.path
        let openedPath = opened.standardizedFileURL.path

        if sourcePath == tempPath {
            return openedPath
        }

        if sourcePath.hasPrefix(tempPath + "/") {
            let relative = String(sourcePath.dropFirst(tempPath.count + 1))
            return openedPath + "#" + relative
        }

        return sourcePath
    }

    /// Best-effort secondary key derived from `(filesystem-id, file-id)`.
    /// Returned only when both values are available; nil otherwise so the
    /// caller can fall back to the path-based key without changing schema.
    ///
    /// Use case: external drives whose mount path changes ("/Volumes/My
    /// Drive" → "/Volumes/My Drive 1" on re-mount) keep the same inode
    /// pair, so a previously-saved position can still be located. Stored
    /// alongside (not in place of) the path key.
    static func fileIdentity(for url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [
            .volumeIdentifierKey,
            .fileResourceIdentifierKey,
        ])
        guard
            let vol = values?.volumeIdentifier as? NSObject,
            let fid = values?.fileResourceIdentifier as? NSObject
        else { return nil }
        return "fid:\(vol.description)/\(fid.description)"
    }

    /// Secondary key for mount-path drift recovery. Temp-backed volumes use
    /// the opened archive's identity plus the inner path because extraction
    /// paths and extracted file identities are not stable. Normal files and
    /// folder-listed archives use their own identity so sibling books never
    /// share the fallback slot.
    private static func fileIdentityFallback(
        for sourceURL: URL,
        opened openedURL: URL?,
        tempRoot tempDir: URL?
    ) -> String? {
        guard let openedURL,
              let tempDir else {
            return fileIdentity(for: sourceURL)
        }

        let sourcePath = sourceURL.standardizedFileURL.path
        let tempPath = tempDir.standardizedFileURL.path

        if sourcePath == tempPath {
            return fileIdentity(for: openedURL)
        }

        guard sourcePath.hasPrefix(tempPath + "/") else {
            return fileIdentity(for: sourceURL)
        }

        guard let openedIdentity = fileIdentity(for: openedURL) else {
            return nil
        }
        let relative = String(sourcePath.dropFirst(tempPath.count + 1))
        return openedIdentity + "#" + relative
    }
}
