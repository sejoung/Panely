import Testing
import Foundation
import CoreServices
@testable import Panely

/// The library tree scan: a cancelled scan (superseded by a newer refresh)
/// must never reach the sidebar, a later refresh must still produce the full
/// tree, and what the scanner lists must match what the directory watcher's
/// filter considers a tree change.
@MainActor
@Suite(.serialized)
struct LibraryTreeScanTests {

    private let root = URL(fileURLWithPath: "/scan-lib", isDirectory: true)

    @Test func cancelledDeepScanNeverPublishesItsPartialTree() async {
        let loader = GatedTreeLoader()
        let model = LibrarySidebarModel()
        let shallow = [folder("A"), folder("B"), folder("C")]
        let partial = [folder("A", children: [archive("A1", in: "A")])]
        let full = [
            folder("A", children: [archive("A1", in: "A")]),
            folder("B", children: [archive("B1", in: "B")]),
            folder("C"),
        ]

        let first = Task { await model.reload(rootURL: root, loader: loader) }
        await loader.respond(to: 1, with: shallow)
        await loader.waitForCall(2)
        // A newer refresh supersedes this one mid deep scan; the scan stops
        // early and hands back what it had.
        first.cancel()
        await loader.respond(to: 2, with: partial)
        await first.value

        #expect(model.nodes == shallow)
        #expect(model.scanCompleted)

        // The next refresh of the same root still delivers the whole tree.
        let second = Task { await model.reload(rootURL: root, loader: loader) }
        await loader.respond(to: 3, with: full)
        await second.value
        #expect(await loader.requestedDepths == [1, LibrarySidebarModel.deepScanDepth, LibrarySidebarModel.deepScanDepth])
        #expect(model.nodes == full)
        #expect(model.scanCompleted)
    }

    @Test func refreshAfterACancelledFirstPaintCompletesTheScan() async {
        let loader = GatedTreeLoader()
        let model = LibrarySidebarModel()
        let full = [folder("A", children: [archive("A1", in: "A")]), archive("Top")]

        let first = Task { await model.reload(rootURL: root, loader: loader) }
        await loader.waitForCall(1)
        first.cancel()
        await loader.respond(to: 1, with: [folder("A")])
        await first.value
        #expect(model.nodes.isEmpty)
        #expect(!model.scanCompleted)

        let second = Task { await model.reload(rootURL: root, loader: loader) }
        await loader.respond(to: 2, with: full)
        await second.value
        #expect(model.nodes == full)
        // The spinner must not be left running for a root whose first paint
        // was cancelled.
        #expect(model.scanCompleted)
    }

    @Test func cancelledLoadTreeStopsBeforeListing() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["A", "B", "C"] {
            let sub = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Fixture.writeFile(sub.appendingPathComponent("Vol.cbz"))
        }

        let task = Task { await FileNode.loadTree(from: dir, maxDepth: 3) }
        task.cancel()  // before the task ever runs
        #expect(await task.value.isEmpty)
        #expect(await FileNode.loadTree(from: dir, maxDepth: 3).count == 3)
    }

    /// The scanner and `LibraryChangeFilter` encode the same rules (depth,
    /// hidden entries, `__MACOSX`, supported archives) independently. For
    /// every entry of a real tree, "creating it is a relevant change" must
    /// equal "it shows up in the scanned tree" — otherwise the watcher either
    /// misses new books or rescans on noise.
    @Test func scannerAndWatcherFilterAgreeOnWhatTheTreeShows() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries: [(path: String, isDirectory: Bool)] = [
            ("Top.cbz", false),
            ("notes.txt", false),
            (".DS_Store", false),
            (".hidden", true),
            (".hidden/X.cbz", false),
            ("__MACOSX", true),
            ("__MACOSX/Y.cbz", false),
            ("Empty", true),
            ("A", true),
            ("A/A1.cbr", false),
            ("A/page.jpg", false),
            ("A/.git", true),
            ("A/__MACOSX", true),
            ("A/B", true),
            ("A/B/B1.zip", false),
            ("A/B/._B1.zip", false),
            ("A/B/C", true),
            ("A/B/C/C1.cbz", false),
            ("A/B/C/D", true),
            ("A/B/C/D/D1.cbz", false),
        ]
        for entry in entries {
            let url = dir.appendingPathComponent(entry.path, isDirectory: entry.isDirectory)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Fixture.writeFile(url)
            }
        }

        let depth = LibrarySidebarModel.deepScanDepth
        let tree = await FileNode.loadTree(from: dir, maxDepth: depth)
        let listed = Set(flatten(tree).map { $0.standardizedURL.path })
        let filter = LibraryChangeFilter(root: dir, maxDepth: depth)

        for entry in entries {
            let path = dir.appendingPathComponent(entry.path).standardizedFileURL.path
            let kind = entry.isDirectory ? kFSEventStreamEventFlagItemIsDir : kFSEventStreamEventFlagItemIsFile
            let flags = FSEventStreamEventFlags(kind | kFSEventStreamEventFlagItemCreated)
            #expect(
                filter.isRelevant(path: path, flags: flags) == listed.contains(path),
                "\(entry.path): filter and scanner disagree"
            )
        }
        // And the expected shape, so both can't drift together.
        #expect(tree.map(\.name) == ["A", "Empty", "Top"])
        let a = try #require(tree.first)
        #expect(a.children?.map(\.name) == ["A1", "B"])
        let b = try #require(a.children?.last)
        #expect(b.children?.map(\.name) == ["B1", "C"])
        #expect(b.children?.last?.children == nil)
        #expect(tree[1].children == nil)
    }

    // MARK: - Helpers

    private func flatten(_ nodes: [FileNode]) -> [FileNode] {
        nodes.flatMap { [$0] + flatten($0.children ?? []) }
    }

    private func folder(_ path: String, children: [FileNode]? = nil) -> FileNode {
        let url = root.appendingPathComponent(path, isDirectory: true)
        return FileNode(id: url, url: url, name: url.lastPathComponent, kind: .folder, children: children)
    }

    private func archive(_ name: String, in parent: String? = nil) -> FileNode {
        let base = parent.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        let url = base.appendingPathComponent(name + ".cbz")
        return FileNode(id: url, url: url, name: name, kind: .archive, children: nil)
    }
}

/// Holds every `loadTree` call until the test answers it, so a test can
/// cancel a reload at an exact point of the scan.
private actor GatedTreeLoader: LibraryTreeLoading {
    private(set) var requestedDepths: [Int] = []
    private var pending: [Int: CheckedContinuation<[FileNode], Never>] = [:]
    private var callWaiters: [(call: Int, continuation: CheckedContinuation<Void, Never>)] = []

    nonisolated func loadTree(from url: URL, maxDepth: Int) async -> [FileNode] {
        await enqueue(maxDepth: maxDepth)
    }

    private func enqueue(maxDepth: Int) async -> [FileNode] {
        requestedDepths.append(maxDepth)
        let call = requestedDepths.count
        return await withCheckedContinuation { continuation in
            pending[call] = continuation
            let ready = callWaiters.filter { $0.call <= call }
            callWaiters.removeAll { $0.call <= call }
            ready.forEach { $0.continuation.resume() }
        }
    }

    /// Wait until the `call`-th (1-based) `loadTree` call is waiting.
    func waitForCall(_ call: Int) async {
        if pending[call] != nil || requestedDepths.count > call { return }
        await withCheckedContinuation { callWaiters.append((call, $0)) }
    }

    func respond(to call: Int, with nodes: [FileNode]) async {
        await waitForCall(call)
        pending.removeValue(forKey: call)?.resume(returning: nodes)
    }
}
