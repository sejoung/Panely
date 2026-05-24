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
}
