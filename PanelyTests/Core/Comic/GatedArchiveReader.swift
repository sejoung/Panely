import Foundation
@testable import Panely

/// A latch a test opens to let blocked `GatedArchiveReader.loadData` calls
/// through, recording what each read saw. Lets a test pin the order in which
/// concurrent page decodes finish — "the superseded read completes *after*
/// its replacement" — instead of hoping a sleep lands it there.
///
/// Reads block a thread while closed (`ArchiveReader.loadData` is
/// synchronous on the actor), so every wait is bounded and tests must open
/// the gate on every path (`defer { gate.open() }`).
final class ReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen: Bool
    private var _arrivals = 0
    private var _sawCancellation: [Bool] = []

    init(open: Bool = false) {
        isOpen = open
    }

    /// Reads that reached the gate (blocked or not).
    var arrivals: Int {
        condition.lock()
        defer { condition.unlock() }
        return _arrivals
    }

    /// `Task.isCancelled` of each read, observed once the gate let it through.
    var sawCancellation: [Bool] {
        condition.lock()
        defer { condition.unlock() }
        return _sawCancellation
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks until the gate opens (at most 10 s, so a broken test fails
    /// instead of hanging the run).
    fileprivate func pass() {
        condition.lock()
        _arrivals += 1
        let deadline = Date().addingTimeInterval(10)
        while !isOpen {
            if !condition.wait(until: deadline) { break }
        }
        condition.unlock()
    }

    fileprivate func record(cancelled: Bool) {
        condition.lock()
        _sawCancellation.append(cancelled)
        condition.unlock()
    }
}

/// In-memory `ArchiveReader` whose full reads wait on a `ReadGate`. Prefix
/// reads (dimension pre-pass) never wait, so a vertical refresh can lay out
/// the strip while a page decode is held.
///
/// `honorsCancellation` mirrors the real readers, which throw
/// `CancellationError` from a read whose task was cancelled; `false` models a
/// reader that returns its bytes regardless, leaving it to `ImageLoader`.
actor GatedArchiveReader: ArchiveReader {
    nonisolated let archiveURL: URL
    private let entries: [String: Data]
    private let gate: ReadGate
    private let honorsCancellation: Bool

    init(entries: [String: Data], gate: ReadGate, honorsCancellation: Bool = true) {
        self.archiveURL = URL(fileURLWithPath: "/nonexistent/gated-\(UUID().uuidString).cbz")
        self.entries = entries
        self.gate = gate
        self.honorsCancellation = honorsCancellation
    }

    func entryPaths() -> [String] {
        entries.keys.sorted()
    }

    func loadData(at path: String) throws -> Data {
        gate.pass()
        let cancelled = Task.isCancelled
        gate.record(cancelled: cancelled)
        if honorsCancellation && cancelled { throw CancellationError() }
        guard let data = entries[path] else { throw ArchiveReaderError.entryNotFound(path) }
        return data
    }

    func loadDataPrefix(at path: String, maxBytes: Int) throws -> Data {
        guard let data = entries[path] else { throw ArchiveReaderError.entryNotFound(path) }
        return data.prefix(maxBytes)
    }

    /// A page backed by its own gated reader holding one PNG of `size`.
    static func page(
        named name: String,
        size: CGSize,
        gate: ReadGate,
        honorsCancellation: Bool = true
    ) throws -> ComicPage {
        let png = try Fixture.makePNG(width: Int(size.width), height: Int(size.height))
        let reader = GatedArchiveReader(entries: [name: png], gate: gate, honorsCancellation: honorsCancellation)
        return ComicPage(source: .archiveEntry(reader: reader, path: name), displayName: name)
    }
}
