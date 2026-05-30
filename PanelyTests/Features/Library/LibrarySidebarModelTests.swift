import Foundation
import Testing
@testable import Panely

@MainActor
struct LibrarySidebarModelTests {
    @Test func reloadClearsStateWhenRootIsNil() async {
        let model = LibrarySidebarModel()
        model.expandedNodeIDs = [URL(fileURLWithPath: "/old")]

        await model.reload(rootURL: nil, loader: FakeLibraryTreeLoader())

        #expect(model.nodes.isEmpty)
        #expect(model.scanCompleted == false)
        #expect(model.expandedNodeIDs.isEmpty)
    }

    @Test func reloadBuildsFileTree() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try Fixture.writeFile(root.appendingPathComponent("Vol01.cbz"))
        _ = try Fixture.writeFile(nested.appendingPathComponent("Vol02.cbz"))

        let model = LibrarySidebarModel()
        await model.reload(rootURL: root, loader: LiveLibraryTreeLoader())

        #expect(model.scanCompleted)
        #expect(model.nodes.contains { $0.name == "Vol01" })
        #expect(model.nodes.contains { $0.name == "Nested" })
    }

    @Test func reloadUsesInjectedTreeLoader() async {
        let model = LibrarySidebarModel()

        await model.reload(
            rootURL: URL(fileURLWithPath: "/fake-library", isDirectory: true),
            loader: FakeLibraryTreeLoader()
        )

        #expect(model.scanCompleted)
        #expect(model.nodes.map(\.name) == ["depth-3"])
    }

    @Test func reloadExpandsAncestorsOfActiveURL() async {
        let root = URL(fileURLWithPath: "/fake-library", isDirectory: true)
        let series = root.appendingPathComponent("Series", isDirectory: true)
        let active = series.appendingPathComponent("Vol01.cbz")
        let model = LibrarySidebarModel()

        await model.reload(
            rootURL: root,
            activeURL: active,
            loader: NestedLibraryTreeLoader()
        )

        #expect(model.expandedNodeIDs.contains(series))
    }

    @Test func expandAncestorsKeepsUserExpandedFolders() async {
        let root = URL(fileURLWithPath: "/fake-library", isDirectory: true)
        let manual = root.appendingPathComponent("Manual", isDirectory: true)
        let series = root.appendingPathComponent("Series", isDirectory: true)
        let active = series.appendingPathComponent("Vol01.cbz")
        let model = LibrarySidebarModel()

        await model.reload(rootURL: root, loader: NestedLibraryTreeLoader())
        model.expandedNodeIDs.insert(manual)
        model.expandAncestors(of: active)

        #expect(model.expandedNodeIDs.contains(manual))
        #expect(model.expandedNodeIDs.contains(series))
    }

    @Test func reloadClearsPreviousNodesBeforeLoadingNewRoot() async {
        let model = LibrarySidebarModel()
        await model.reload(
            rootURL: URL(fileURLWithPath: "/old-library", isDirectory: true),
            loader: FakeLibraryTreeLoader()
        )
        #expect(model.nodes.isEmpty == false)

        let loader = SuspendedLibraryTreeLoader()
        let task = Task {
            await model.reload(
                rootURL: URL(fileURLWithPath: "/new-library", isDirectory: true),
                loader: loader
            )
        }
        await loader.waitUntilStarted()

        #expect(model.nodes.isEmpty)
        #expect(model.scanCompleted == false)

        await loader.finish()
        await task.value
    }

    // MARK: - Same-root refresh (no flash) vs root switch

    @Test func sameRootRefreshSkipsShallowPassAndKeepsNodes() async {
        let root = URL(fileURLWithPath: "/lib", isDirectory: true)
        let deep = [node("a.cbz", under: root), node("b.cbz", under: root)]
        let loader = StubTreeLoader(shallow: deep, deep: deep)
        let model = LibrarySidebarModel()

        await model.reload(rootURL: root, loader: loader)
        #expect(loader.loadCount == 2)        // new root: shallow + deep
        #expect(model.nodes.count == 2)

        await model.reload(rootURL: root, loader: loader)
        // Same-root refresh runs the deep scan only — no shallow pass — so the
        // populated tree is never swapped to a collapsed depth-1 version (the
        // flash this change removes).
        #expect(loader.loadCount == 3)
        #expect(model.nodes.count == 2)
    }

    @Test func sameRootRefreshPicksUpNewFile() async {
        let root = URL(fileURLWithPath: "/lib", isDirectory: true)
        let loader = StubTreeLoader(
            shallow: [node("a.cbz", under: root)],
            deep: [node("a.cbz", under: root)]
        )
        let model = LibrarySidebarModel()
        await model.reload(rootURL: root, loader: loader)
        #expect(model.nodes.map(\.name) == ["a"])

        // New file lands on disk; the next refresh surfaces it.
        loader.deep = [node("a.cbz", under: root), node("b.cbz", under: root)]
        await model.reload(rootURL: root, loader: loader)
        #expect(model.nodes.map(\.name) == ["a", "b"])
    }

    @Test func rootSwitchStillReplacesTree() async {
        let rootA = URL(fileURLWithPath: "/libA", isDirectory: true)
        let loaderA = StubTreeLoader(
            shallow: [node("a.cbz", under: rootA)],
            deep: [node("a.cbz", under: rootA)]
        )
        let model = LibrarySidebarModel()
        await model.reload(rootURL: rootA, loader: loaderA)
        #expect(model.nodes.map(\.name) == ["a"])

        let rootB = URL(fileURLWithPath: "/libB", isDirectory: true)
        let loaderB = StubTreeLoader(
            shallow: [node("z.cbz", under: rootB)],
            deep: [node("z.cbz", under: rootB)]
        )
        await model.reload(rootURL: rootB, loader: loaderB)

        #expect(model.nodes.map(\.name) == ["z"])
        #expect(loaderB.loadCount == 2)       // switch keeps fast shallow-first repaint
    }

    private func node(_ fileName: String, under root: URL) -> FileNode {
        let url = root.appendingPathComponent(fileName)
        return FileNode(id: url, url: url, name: (fileName as NSString).deletingPathExtension, kind: .archive, children: nil)
    }
}

private final class StubTreeLoader: LibraryTreeLoading, @unchecked Sendable {
    var shallow: [FileNode]
    var deep: [FileNode]
    private(set) var loadCount = 0

    init(shallow: [FileNode], deep: [FileNode]) {
        self.shallow = shallow
        self.deep = deep
    }

    func loadTree(from url: URL, maxDepth: Int) async -> [FileNode] {
        loadCount += 1
        return maxDepth <= 1 ? shallow : deep
    }
}

private nonisolated struct FakeLibraryTreeLoader: LibraryTreeLoading {
    func loadTree(from url: URL, maxDepth: Int) async -> [FileNode] {
        [
            FileNode(
                id: url.appendingPathComponent("depth-\(maxDepth).cbz"),
                url: url.appendingPathComponent("depth-\(maxDepth).cbz"),
                name: "depth-\(maxDepth)",
                kind: .archive,
                children: nil
            ),
        ]
    }
}

private nonisolated struct NestedLibraryTreeLoader: LibraryTreeLoading {
    func loadTree(from url: URL, maxDepth: Int) async -> [FileNode] {
        let series = url.appendingPathComponent("Series", isDirectory: true)
        let manual = url.appendingPathComponent("Manual", isDirectory: true)
        return [
            FileNode(
                id: manual,
                url: manual,
                name: "Manual",
                kind: .folder,
                children: nil
            ),
            FileNode(
                id: series,
                url: series,
                name: "Series",
                kind: .folder,
                children: [
                    FileNode(
                        id: series.appendingPathComponent("Vol01.cbz"),
                        url: series.appendingPathComponent("Vol01.cbz"),
                        name: "Vol01",
                        kind: .archive,
                        children: nil
                    ),
                ]
            ),
        ]
    }
}

private actor SuspendedLibraryTreeLoader: LibraryTreeLoading {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var didSuspend = false
    private var didFinish = false

    nonisolated func loadTree(from url: URL, maxDepth: Int) async -> [FileNode] {
        await markStarted()
        await waitForFinishIfNeeded()
        return [
            FileNode(
                id: url.appendingPathComponent("loaded-\(maxDepth).cbz"),
                url: url.appendingPathComponent("loaded-\(maxDepth).cbz"),
                name: "loaded-\(maxDepth)",
                kind: .archive,
                children: nil
            ),
        ]
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func finish() {
        didFinish = true
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func markStarted() {
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil
    }

    private func waitForFinishIfNeeded() async {
        guard !didSuspend else { return }
        didSuspend = true
        guard !didFinish else { return }
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }
}
