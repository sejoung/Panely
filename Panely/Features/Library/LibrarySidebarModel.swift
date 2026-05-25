import Foundation

@Observable
@MainActor
final class LibrarySidebarModel {
    private(set) var nodes: [FileNode] = []
    private(set) var scanCompleted = false
    var expandedNodeIDs: Set<URL> = []

    func reload(
        rootURL: URL?,
        activeURL: URL? = nil,
        loader: any LibraryTreeLoading = LiveLibraryTreeLoader()
    ) async {
        guard let rootURL else {
            nodes = []
            scanCompleted = false
            expandedNodeIDs = []
            return
        }
        nodes = []
        scanCompleted = false

        let shallow = await loader.loadTree(from: rootURL, maxDepth: 1)
        if Task.isCancelled { return }
        nodes = shallow
        scanCompleted = true
        expandAncestors(of: activeURL)

        let deep = await loader.loadTree(from: rootURL, maxDepth: 3)
        if Task.isCancelled { return }
        if deep != shallow {
            nodes = deep
            expandAncestors(of: activeURL)
        }
    }

    func expandAncestors(of activeURL: URL?) {
        guard let activeURL else { return }
        let active = activeURL.standardizedFileURL
        let ancestors = Self.ancestorURLs(of: active, in: nodes)
        expandedNodeIDs.formUnion(ancestors)
    }

    private static func ancestorURLs(of activeURL: URL, in nodes: [FileNode]) -> [URL] {
        for node in nodes {
            if node.url.standardizedFileURL == activeURL {
                return []
            }
            if let children = node.children,
               let childPath = ancestorPath(of: activeURL, through: node, children: children) {
                return childPath
            }
        }
        return []
    }

    private static func ancestorPath(
        of activeURL: URL,
        through node: FileNode,
        children: [FileNode]
    ) -> [URL]? {
        for child in children {
            if child.url.standardizedFileURL == activeURL {
                return [node.id]
            }
            if let grandchildren = child.children,
               let path = ancestorPath(of: activeURL, through: child, children: grandchildren) {
                return [node.id] + path
            }
        }
        return nil
    }
}
