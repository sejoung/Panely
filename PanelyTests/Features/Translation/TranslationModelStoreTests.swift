import CryptoKit
import Foundation
import Testing
@testable import Panely

/// The model's download (`TranslationModelStore`) and its file
/// (`TranslationModelFiles`): only a file of the pinned size and hash is ever
/// installed, and the store's state follows the download.
@MainActor
struct TranslationModelStoreTests {
    nonisolated private static let content = Data("not really a model, but pinned like one".utf8)

    nonisolated private static func model(content: Data = content) -> TranslationModel {
        TranslationModel(
            id: "test-model",
            displayName: "Test Model",
            revision: "0123456789abcdef",
            fileName: "test.gguf",
            bytes: Int64(content.count),
            sha256: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://example.invalid/test.gguf")!,
            license: "Apache-2.0"
        )
    }

    private func makeFiles(model: TranslationModel = model()) throws -> TranslationModelFiles {
        TranslationModelFiles(root: try Fixture.makeTempDir().appendingPathComponent("models", isDirectory: true), model: model)
    }

    @Test func pinnedModelIsGoogleGemmaAtOneRevision() {
        let model = TranslationModel.current
        #expect(model.url.absoluteString.contains("/resolve/\(model.revision)/"))
        #expect(model.url.host == "huggingface.co")
        #expect(model.sha256.count == 64)
        #expect(TranslationModel.cacheRevision == "gemma-4-e2b-it-q4_0@675cff42a74c+p1")
    }

    @Test func installChecksSizeAndHashBeforeMovingIntoPlace() throws {
        let files = try makeFiles()
        #expect(!files.isInstalled)
        let staging = try Fixture.makeTempDir().appendingPathComponent("download")

        try Data("short".utf8).write(to: staging)
        #expect(throws: TranslationModelError.self) { try files.install(downloadedFile: staging) }
        #expect(!files.isInstalled)

        var damaged = Self.content
        damaged[0] ^= 0xFF
        try damaged.write(to: staging)
        #expect(throws: TranslationModelError.hashMismatch) { try files.install(downloadedFile: staging) }
        #expect(!files.isInstalled)

        try Self.content.write(to: staging)
        try files.install(downloadedFile: staging)
        #expect(files.isInstalled)
        #expect(try Data(contentsOf: files.fileURL) == Self.content)
        #expect(!FileManager.default.fileExists(atPath: staging.path))

        #expect(files.remove() == Int64(Self.content.count))
        #expect(!files.isInstalled)
    }

    @Test func hashIsReadInPiecesAndMatchesCryptoKit() throws {
        let file = try Fixture.makeTempDir().appendingPathComponent("big")
        // Bigger than one 8 MB piece.
        let data = Data((0..<(9 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: file)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(try TranslationModelFiles.sha256(of: file) == expected)
    }

    @Test func downloadReportsProgressThenInstallsAndTellsWhoIsWaiting() async throws {
        let files = try makeFiles()
        let gate = TranslationPermitGate()
        let store = TranslationModelStore(files: files, downloader: DataModelDownloader(data: Self.content, gate: gate))
        var installed = 0
        store.onInstalled = { installed += 1 }
        #expect(store.state == .notInstalled)

        store.download()
        #expect(store.isDownloading)
        try await waitUntil { store.fractionDownloaded.map { $0 > 0 && $0 < 1 } == true }
        #expect(!files.isInstalled)

        await gate.release()
        try await waitUntil { store.state == .installed }
        #expect(files.isInstalled)
        #expect(installed == 1)
        #expect(store.fractionDownloaded == nil)
        // No leftovers next to the model.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: files.root.path).filter { $0.hasSuffix(".download") }
        #expect(leftovers.isEmpty)

        await store.remove()
        #expect(store.state == .notInstalled)
        #expect(!files.isInstalled)
    }

    @Test func aDamagedDownloadFailsAndLeavesNothingInstalled() async throws {
        let files = try makeFiles()
        var damaged = Self.content
        damaged[3] ^= 0x01
        let store = TranslationModelStore(files: files, downloader: DataModelDownloader(data: damaged))
        var installed = 0
        store.onInstalled = { installed += 1 }

        store.download()
        try await waitUntil { if case .failed = store.state { true } else { false } }
        #expect(!files.isInstalled)
        #expect(installed == 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: files.root.path).filter { $0.hasSuffix(".download") }
        #expect(leftovers.isEmpty)
    }

    @Test func cancellingStopsTheDownload() async throws {
        let files = try makeFiles()
        let gate = TranslationPermitGate()
        let store = TranslationModelStore(files: files, downloader: DataModelDownloader(data: Self.content, gate: gate))

        store.download()
        try await waitUntil { store.fractionDownloaded.map { $0 > 0 && $0 < 1 } == true }
        store.cancelDownload()
        #expect(store.state == .notInstalled)
        await gate.open()
        // Whatever the cancelled download does on its way out, it installs nothing.
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.state == .notInstalled)
        #expect(!files.isInstalled)
    }

    @Test func aModelAlreadyOnDiskIsInstalledFromTheStart() throws {
        let files = try makeFiles()
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Self.content.write(to: files.fileURL)
        let store = TranslationModelStore(files: files, downloader: FailingModelDownloader())
        #expect(store.isInstalled)
        // Already there: nothing to download.
        store.download()
        #expect(store.isInstalled)
    }
}
