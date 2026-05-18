import Foundation

nonisolated struct FileNode: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let name: String
    let kind: Kind
    var children: [FileNode]?

    nonisolated enum Kind: Hashable, Sendable {
        case folder
        case archive
    }

    var iconName: String {
        switch kind {
        case .folder:  return "folder"
        case .archive: return "doc.zipper"
        }
    }

    var fileExtension: String? {
        guard kind == .archive else { return nil }
        let ext = url.pathExtension
        return ext.isEmpty ? nil : ext.lowercased()
    }

    static func loadTree(from url: URL, maxDepth: Int = 3) async -> [FileNode] {
        // Top-level scan parallelizes per-entry subtree builds. Each
        // subtree's recursion stays serial — that gives ~chunk-wide speedup
        // without exploding the task pool with N^depth concurrent tasks.
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let chunkSize = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        var nodes: [FileNode] = []

        for chunkStart in stride(from: 0, to: contents.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, contents.count)
            let chunk = Array(contents[chunkStart..<chunkEnd])
            let chunkNodes = await withTaskGroup(of: FileNode?.self, returning: [FileNode].self) { group in
                for entry in chunk {
                    group.addTask {
                        Self.processEntry(entry, depth: 0, maxDepth: maxDepth)
                    }
                }
                var results: [FileNode] = []
                for await node in group {
                    if let node {
                        results.append(node)
                    }
                }
                return results
            }
            nodes.append(contentsOf: chunkNodes)
        }

        return nodes.sorted { a, b in
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func processEntry(_ entry: URL, depth: Int, maxDepth: Int) -> FileNode? {
        let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let ext = entry.pathExtension.lowercased()

        if isDir {
            let children: [FileNode]?
            if depth < maxDepth - 1 {
                let loaded = buildTreeSerial(at: entry, depth: depth + 1, maxDepth: maxDepth)
                children = loaded.isEmpty ? nil : loaded
            } else {
                children = nil
            }
            return FileNode(
                id: entry,
                url: entry,
                name: entry.lastPathComponent,
                kind: .folder,
                children: children
            )
        } else if CBZLoader.supportedExtensions.contains(ext) {
            return FileNode(
                id: entry,
                url: entry,
                name: entry.deletingPathExtension().lastPathComponent,
                kind: .archive,
                children: nil
            )
        }
        return nil
    }

    /// Serial subtree build used inside parallel top-level chunks.
    /// Avoids nested TaskGroup explosion (would be N^depth tasks).
    private static func buildTreeSerial(at url: URL, depth: Int, maxDepth: Int) -> [FileNode] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var nodes: [FileNode] = []
        for entry in contents {
            if let node = processEntry(entry, depth: depth, maxDepth: maxDepth) {
                nodes.append(node)
            }
        }

        return nodes.sorted { a, b in
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
