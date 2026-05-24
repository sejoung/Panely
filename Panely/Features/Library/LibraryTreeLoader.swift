import Foundation

nonisolated protocol LibraryTreeLoading: Sendable {
    func loadTree(from url: URL, maxDepth: Int) async -> [FileNode]
}

nonisolated struct LiveLibraryTreeLoader: LibraryTreeLoading {
    func loadTree(from url: URL, maxDepth: Int) async -> [FileNode] {
        await FileNode.loadTree(from: url, maxDepth: maxDepth)
    }
}
