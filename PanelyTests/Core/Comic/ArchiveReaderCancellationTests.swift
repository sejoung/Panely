import Testing
import AppKit
import Foundation
import ZIPFoundation
@testable import Panely

/// Superseded page reads (slider scrub, fast paging, scrolling) are cancelled.
/// The readers must turn a cancelled read into `CancellationError` — never
/// into bytes, and never into a different error that the reader UI would
/// report as "Failed to load" — and stay usable afterwards.
struct ArchiveReaderCancellationTests {
    // MARK: - ZIP

    @Test func cancelledZIPReadThrowsCancellation() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let zipURL = try ZIPArchiveIndexEquivalenceTests.makeMixedArchive(in: workDir)
        let reader = try ZIPArchiveReader(url: zipURL)

        await #expect(throws: CancellationError.self) {
            try await Self.inCancelledTask { _ = try await reader.loadData(at: "big.bin") }
        }
        // The actor isn't left wedged by the abandoned read.
        let data = try await reader.loadData(at: "big.bin")
        #expect(data.count == 300_000)
    }

    @Test func cancelledZIPPrefixReadThrowsCancellation() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let zipURL = try ZIPArchiveIndexEquivalenceTests.makeMixedArchive(in: workDir)
        let reader = try ZIPArchiveReader(url: zipURL)

        await #expect(throws: CancellationError.self) {
            try await Self.inCancelledTask { _ = try await reader.loadDataPrefix(at: "big.bin", maxBytes: 64) }
        }
        let prefix = try await reader.loadDataPrefix(at: "big.bin", maxBytes: 64)
        #expect(prefix.count >= 64)
    }

    // MARK: - RAR

    @Test(arguments: ["panely-rar5.cbr", "panely-rar5-solid.cbr"])
    func cancelledRARReadThrowsCancellation(fixture: String) async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive(fixture, in: workDir)
        let reader = try RARArchiveReader(url: url)

        await #expect(throws: CancellationError.self) {
            try await Self.inCancelledTask { _ = try await reader.loadData(at: "02.png") }
        }
        await #expect(throws: CancellationError.self) {
            try await Self.inCancelledTask { _ = try await reader.loadDataPrefix(at: "02.png", maxBytes: 64) }
        }
        // Still serves an uncancelled caller.
        let image = try #require(NSImage(data: try await reader.loadData(at: "02.png")))
        #expect(image.size == CGSize(width: 56, height: 78))
    }

    // MARK: - ImageLoader over a reader that ignores cancellation

    /// A page whose read was already in flight when its caller was cancelled
    /// (the reader returns its bytes anyway) must not go on to decode: the
    /// cancelled caller gets `CancellationError`, not an image.
    @Test func readFinishingAfterCancellationIsNotDecoded() async throws {
        let gate = ReadGate()
        defer { gate.open() }
        let page = try GatedArchiveReader.page(
            named: "001.png",
            size: CGSize(width: 30, height: 40),
            gate: gate,
            honorsCancellation: false
        )

        let task = Task { try await ImageLoader.load(page) }
        try await Self.waitFor { gate.arrivals == 1 }
        task.cancel()
        gate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(gate.sawCancellation == [true])
    }

    // MARK: - Helpers

    /// Runs `body` inside a task that is already cancelled when it starts.
    static func inCancelledTask(_ body: @escaping @Sendable () async throws -> Void) async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await body()
        }
        try await task.value
    }

    /// Off-main poll (these tests aren't main-actor bound).
    static func waitFor(timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
