import Foundation

@Observable
@MainActor
final class LibrarySidebarModel {
    private(set) var nodes: [FileNode] = []
    private(set) var scanCompleted = false
    var expandedNodeIDs: Set<URL> = []
    /// Root the current `nodes` were loaded from. Lets `reload` tell a genuine
    /// root switch (blank + shallow-first repaint) from a same-root refresh
    /// (keep the tree on screen, swap only on a real diff).
    private var lastLoadedRoot: URL?

    func reload(
        rootURL: URL?,
        activeURL: URL? = nil,
        loader: any LibraryTreeLoading
    ) async {
        guard let rootURL else {
            nodes = []
            scanCompleted = false
            expandedNodeIDs = []
            lastLoadedRoot = nil
            return
        }

        let isRootSwitch = lastLoadedRoot?.standardizedFileURL != rootURL.standardizedFileURL
        lastLoadedRoot = rootURL

        if isRootSwitch {
            // New root: blank and shallow-scan first so the tree paints fast.
            nodes = []
            scanCompleted = false

            let shallow = await loader.loadTree(from: rootURL, maxDepth: 1)
            if Task.isCancelled { return }
            nodes = shallow
            scanCompleted = true
            expandAncestors(of: activeURL)
        }
        // Same-root refresh (manual button / directory-watch) skips the
        // shallow pass entirely: blanking or swapping in a depth-1 tree would
        // flash the existing deep tree to a collapsed state. Go straight to the
        // deep scan and replace only when it actually differs — a no-change
        // refresh then touches nothing (no flicker, no relayout).

        let deep = await loader.loadTree(from: rootURL, maxDepth: 3)
        if Task.isCancelled { return }
        if deep != nodes {
            nodes = deep
            expandAncestors(of: activeURL)
        }
        scanCompleted = true
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
