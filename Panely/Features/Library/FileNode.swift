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
        await Task.detached(priority: .userInitiated) {
            buildTree(at: url, depth: 0, maxDepth: maxDepth)
        }.value
    }

    private static func buildTree(at url: URL, depth: Int, maxDepth: Int) -> [FileNode] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var nodes: [FileNode] = []
        for entry in contents {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let ext = entry.pathExtension.lowercased()

            if isDir {
                let children: [FileNode]?
                if depth < maxDepth - 1 {
                    let loaded = buildTree(at: entry, depth: depth + 1, maxDepth: maxDepth)
                    children = loaded.isEmpty ? nil : loaded
                } else {
                    children = nil
                }
                nodes.append(FileNode(
                    id: entry,
                    url: entry,
                    name: entry.lastPathComponent,
                    kind: .folder,
                    children: children
                ))
            } else if CBZLoader.supportedExtensions.contains(ext) {
                nodes.append(FileNode(
                    id: entry,
                    url: entry,
                    name: entry.deletingPathExtension().lastPathComponent,
                    kind: .archive,
                    children: nil
                ))
            }
        }

        return nodes.sorted { a, b in
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
