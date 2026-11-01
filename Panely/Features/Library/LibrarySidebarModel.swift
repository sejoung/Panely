import Foundation

@Observable
@MainActor
final class LibrarySidebarModel {
    /// How deep the full (second-pass) scan lists the library. The directory
    /// watcher ignores changes below this depth, which the tree never shows.
    nonisolated static let deepScanDepth = 3

    private(set) var nodes: [FileNode] = []
    private(set) var scanCompleted = false
    var expandedNodeIDs: Set<URL> = []
    /// Root the current `nodes` were loaded from. Lets `reload` tell a genuine
    /// root switch (blank + shallow-first repaint) from a same-root refresh
    /// (keep the tree on screen, swap only on a real diff).
    private var lastLoadedRoot: URL?
    /// Refresh token of the last scan that ran to completion. The model
    /// outlives the sidebar view (the overlay sidebar is mounted per reveal),
    /// so a remount re-runs `.task` with nothing new to find; this lets that
    /// run skip the scan.
    private var lastCompletedToken: UUID?

    /// `refreshToken` identifies the refresh being asked for: a repeat of a
    /// completed one for the same root touches nothing but the expansion.
    func reload(
        rootURL: URL?,
        activeURL: URL? = nil,
        refreshToken: UUID? = nil,
        loader: any LibraryTreeLoading
    ) async {
        guard let rootURL else {
            nodes = []
            scanCompleted = false
            expandedNodeIDs = []
            lastLoadedRoot = nil
            lastCompletedToken = nil
            return
        }

        let isRootSwitch = lastLoadedRoot?.standardizedFileURL != rootURL.standardizedFileURL
        if !isRootSwitch, let refreshToken, refreshToken == lastCompletedToken {
            expandAncestors(of: activeURL)
            return
        }

        lastLoadedRoot = rootURL

        if isRootSwitch {
            lastCompletedToken = nil
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

        let deep = await loader.loadTree(from: rootURL, maxDepth: Self.deepScanDepth)
        if Task.isCancelled { return }
        // Deep-compare off the main actor; a same-root refresh of a big
        // library otherwise walks two full trees on the main thread.
        let changed = await FileNode.treesDiffer(deep, nodes)
        if Task.isCancelled { return }
        if changed {
            nodes = deep
            expandAncestors(of: activeURL)
        }
        scanCompleted = true
        lastCompletedToken = refreshToken
    }

    func expandAncestors(of activeURL: URL?) {
        guard let activeURL else { return }
        let ancestors = Self.ancestorURLs(of: activeURL.standardizedFileURL, in: nodes)
        expandedNodeIDs.formUnion(ancestors)
    }

    /// Runs on the main thread on every book open, so it follows the active
    /// path down rather than walking the tree: at each level only the one
    /// folder whose path prefixes it is entered, and the rest of a large
    /// library is never visited. `[]` when the path doesn't lead to a node.
    private static func ancestorURLs(of activeURL: URL, in nodes: [FileNode]) -> [URL] {
        let activePath = activeURL.path
        var ancestors: [URL] = []
        var level = nodes
        while true {
            var next: FileNode?
            for node in level {
                let path = node.standardizedURL.path
                if path == activePath { return ancestors }
                if next == nil, activePath.hasPrefix(path + "/") { next = node }
            }
            guard let next, let children = next.children else { return [] }
            ancestors.append(next.id)
            level = children
        }
    }
}
