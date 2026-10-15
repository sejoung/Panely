import Foundation
import Testing
@testable import Panely

/// `DiagnosticLogStore` keeps one `FileHandle` open between appends. These
/// pin that the log keeps receiving lines after the file is replaced or
/// removed underneath that handle — by rotation, by `clear()`, or by
/// something outside the app emptying Caches — and that lines land in call
/// order.
struct DiagnosticLogStoreResilienceTests {

    @Test func appendsAfterClearLandInANewFile() async throws {
        try await withStore { store, url in
            await store.record(level: .info, category: .app, message: "before clear")
            #expect(await store.clear())

            await store.record(level: .info, category: .app, message: "after clear")
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("after clear"))
            #expect(!text.contains("before clear"))
        }
    }

    @Test func externalDeletionIsNoticedWithinTheCheckInterval() async throws {
        try await withStore { store, url in
            await store.record(level: .info, category: .app, message: "first")
            try FileManager.default.removeItem(at: url)

            // Lines written to the unlinked file before the periodic
            // existence check are gone; everything after it must land.
            for index in 0..<64 {
                await store.record(level: .info, category: .app, message: "lost-or-kept \(index)")
            }
            await store.record(level: .info, category: .app, message: "after recovery")

            #expect(FileManager.default.fileExists(atPath: url.path))
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("after recovery"))
            #expect(!text.contains("first"))
        }
    }

    @Test func rotationKeepsTheNewestLinesAndKeepsAppending() async throws {
        try await withStore { store, url in
            let filler = String(repeating: "x", count: 1000)
            let lineCount = Int(DiagnosticLogPolicy.maxLogBytes / 1000) + 50
            for index in 0..<lineCount {
                await store.record(level: .info, category: .app, message: "line \(index) \(filler)")
            }
            for index in 0..<5 {
                await store.record(level: .info, category: .app, message: "marker \(index)")
            }

            let size = await store.logSizeBytes()
            #expect(size <= DiagnosticLogPolicy.maxLogBytes)
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("line 0 "))
            #expect(text.contains("line \(lineCount - 1) "))
            for index in 0..<5 { #expect(text.contains("marker \(index)")) }
            // After the (byte-based) trim point, every line is whole.
            let lines = text.split(separator: "\n").dropFirst()
            #expect(lines.allSatisfy { Self.isWellFormed($0) })
        }
    }

    /// The fire-and-forget static path used by `AppLog` funnels through one
    /// FIFO consumer, so sequential calls land in call order.
    @Test func staticRecordPathPreservesCallOrder() async throws {
        let token = "order-\(UUID().uuidString)"
        for index in 0..<300 {
            DiagnosticLogStore.record(level: .info, category: .diagnostics, message: "\(token) \(index)")
        }
        let deadline = ContinuousClock.now + .seconds(10)
        var text = ""
        while ContinuousClock.now < deadline {
            text = await DiagnosticLogStore.shared.recentLogText(maxBytes: 4 * 1024 * 1024)
            if text.contains("\(token) 299\n") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sequence = text.split(separator: "\n")
            .filter { $0.contains(token) }
            .compactMap { Int($0.split(separator: " ").last ?? "") }
        #expect(sequence == Array(0..<300))
    }

    // MARK: - Helpers

    /// `<timestamp> [LEVEL] [category] message`
    private static func isWellFormed(_ line: Substring) -> Bool {
        let parts = line.split(separator: " ", maxSplits: 3)
        guard parts.count == 4 else { return false }
        return parts[0].hasSuffix("Z")
            && parts[1].hasPrefix("[") && parts[1].hasSuffix("]")
            && parts[2].hasPrefix("[") && parts[2].hasSuffix("]")
    }

    private func withStore(_ body: (DiagnosticLogStore, URL) async throws -> Void) async throws {
        let store = DiagnosticLogStore(directoryName: "panely-diagnostics-\(UUID().uuidString)")
        let url = await store.logFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await body(store, url)
    }
}
