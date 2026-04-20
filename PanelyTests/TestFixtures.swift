import Foundation
import ZIPFoundation

enum Fixture {
    static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("panely-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func writeFile(_ url: URL, bytes: [UInt8] = [0]) throws -> URL {
        try Data(bytes).write(to: url)
        return url
    }

    static func zipDirectory(_ sourceDir: URL, to zipURL: URL) throws {
        try FileManager.default.zipItem(at: sourceDir, to: zipURL, shouldKeepParent: false)
    }
}
