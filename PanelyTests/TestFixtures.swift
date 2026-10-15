import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZIPFoundation
@testable import Panely

enum Fixture {
    /// This test run's scratch area: every temp dir and test cache root lives
    /// under it rather than straight in the sandbox's `tmp`.
    ///
    /// Two reasons. Anything a test leaves behind (a view model that's never
    /// freed never runs its cache's `deinit`) used to pile up in `tmp` — 55k
    /// entries after a few weeks — and both opening a folder (which lists the
    /// folder's siblings as volumes) and `ReaderTempDirectory`'s startup sweep
    /// walk that directory, so every run got slower than the last. Now a run
    /// starts by deleting what earlier runs left (anything `paneltest`-
    /// prefixed, or one of the test translation stores, over an hour old, so
    /// a concurrent run's files survive).
    ///
    /// Must not start with `panely-` — `ReaderTempDirectory.cleanupStaleEntries()`
    /// sweeps that prefix at startup and can race with in-flight tests.
    static let runDirectory: URL = {
        let tmp = FileManager.default.temporaryDirectory
        // In the background: after a long gap there can be tens of thousands
        // of entries, and deleting them inline stalled the first tests.
        Task.detached(priority: .background) { sweepEarlierRuns(in: tmp) }
        let dir = tmp.appendingPathComponent("paneltest-run-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func makeTempDir() throws -> URL {
        // Its own parent, so a folder a test opens has no sibling folders
        // for the load to list as volumes (the run's other temp dirs).
        let url = runDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("paneltest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func sweepEarlierRuns(in tmp: URL) {
        let cutoff = Date().addingTimeInterval(-60 * 60)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let prefixes = ["paneltest", "panely-translation-tests-", "panely-translation-edit-tests-"]
        for entry in entries where prefixes.contains(where: entry.lastPathComponent.hasPrefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
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

/// Poll `condition` on the main actor until it holds, failing the test after
/// `timeout`. For work that hops through a background task and has no handle
/// to await. The timeout is generous on purpose: a passing test returns as
/// soon as the condition holds, so it only costs time when the test would
/// fail anyway — and a loaded CI runner can keep the main actor busy for
/// seconds. Never wait out a fixed sleep instead.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met within \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
