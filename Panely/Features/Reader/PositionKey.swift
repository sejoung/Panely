import Foundation

nonisolated enum PositionKey {
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
}
