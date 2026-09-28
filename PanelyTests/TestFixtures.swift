import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation
@testable import Panely

enum Fixture {
    static func makeTempDir() throws -> URL {
        // Must not start with `panely-` — `ReaderTempDirectory.cleanupStaleEntries()`
        // sweeps that prefix at startup and can race with in-flight tests.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paneltest-\(UUID().uuidString)", isDirectory: true)
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

    /// Copies a checked-in archive from `PanelyTests/Fixtures/Archives` into
    /// `dir` (optionally under a new name) so a test can't mutate the bundled
    /// original. RAR fixtures are pre-built — there's no RAR writer to
    /// generate them at test time.
    ///
    /// - `panely-rar5.cbr` / `panely-rar5-solid.cbr`: RAR 5 (plain / solid),
    ///   `01.png` 12×34, `02.png` 56×78, `10.png` 90×120.
    /// - `panely-rar5-nested.cbr`: `vol01.cbz` (01, 02) + `vol02.cbr` (10).
    /// - `panely-rar4.rar`: RAR 4 with `Test File A.txt`, `B.jpg`, `C.m4a`.
    /// - `panely-rar5-password.rar`: encrypted entry data (password "password").
    /// - `panely-rar4-header-password.rar`: encrypted headers.
    static func bundledArchive(_ name: String, in dir: URL, as newName: String? = nil) throws -> URL {
        let bundle = Bundle(for: FixtureBundleToken.self)
        guard let source = bundle.url(forResource: name, withExtension: nil)
            ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Archives")
        else {
            throw NSError(domain: "Fixture", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing fixture \(name)"])
        }
        let destination = dir.appendingPathComponent(newName ?? name)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    static func makeImagePages(count: Int, title: String = "p") -> [ComicPage] {
        do {
            let dir = try makeTempDir()
            let imageData = try makePNG(width: 10, height: 10)
            return try (0..<count).map { index in
                let url = dir.appendingPathComponent("\(title)\(index).png")
                try imageData.write(to: url)
                return ComicPage(source: .file(url), displayName: url.lastPathComponent)
            }
        } catch {
            fatalError("Failed to create test image pages: \(error)")
        }
    }

    /// Generates a real PNG with the given pixel dimensions. Used by tests
    /// that need an image whose header reports a known size (e.g.,
    /// `ImageLoader.dimensions`).
    static func makePNG(width: Int, height: Int) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImg = ctx.makeImage() else {
            throw NSError(domain: "Fixture", code: 1, userInfo: nil)
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "Fixture", code: 2, userInfo: nil)
        }
        CGImageDestinationAddImage(dest, cgImg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Fixture", code: 3, userInfo: nil)
        }
        return mutableData as Data
    }
}

private final class FixtureBundleToken {}
