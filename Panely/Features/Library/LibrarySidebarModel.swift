import Foundation

@Observable
@MainActor
final class LibrarySidebarModel {
    private(set) var nodes: [FileNode] = []
    private(set) var scanCompleted = false

    func reload(
        rootURL: URL?,
        loader: any LibraryTreeLoading = LiveLibraryTreeLoader()
    ) async {
        guard let rootURL else {
            nodes = []
            scanCompleted = false
            return
        }
        scanCompleted = false

        let shallow = await loader.loadTree(from: rootURL, maxDepth: 1)
        if Task.isCancelled { return }
        nodes = shallow
        scanCompleted = true

        let deep = await loader.loadTree(from: rootURL, maxDepth: 3)
        if Task.isCancelled { return }
        if deep != shallow {
            nodes = deep
        }
    }
}
