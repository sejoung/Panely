import Foundation
import Testing
@testable import Panely

@MainActor
struct LibrarySidebarModelTests {
    @Test func reloadClearsStateWhenRootIsNil() async {
        let model = LibrarySidebarModel()

        await model.reload(rootURL: nil)

        #expect(model.nodes.isEmpty)
        #expect(model.scanCompleted == false)
    }

    @Test func reloadBuildsFileTree() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try Fixture.writeFile(root.appendingPathComponent("Vol01.cbz"))
        _ = try Fixture.writeFile(nested.appendingPathComponent("Vol02.cbz"))

        let model = LibrarySidebarModel()
        await model.reload(rootURL: root)

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
