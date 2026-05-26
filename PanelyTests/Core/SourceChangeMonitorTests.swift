import Foundation
import Testing
@testable import Panely

/// Tests for the real `SourceChangeMonitor`. The viewmodel tests use a fake
/// (`TestSourceChangeMonitor`) so the load pipeline can be exercised without
/// touching DispatchSource; these cover the monitor's own behaviour that
/// the fake doesn't simulate — the `.attrib`-exclusion regression and the
/// stale-event race across `stopWatching` / `startWatching` cycles.
///
/// The minute-level `.timeLimit` is a hard cap so a misbehaving DispatchSource
/// (or filesystem) can't hang the whole test process — every test here would
/// normally finish in well under a second.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SourceChangeMonitorTests {
    /// Regression: switching books used to surface a "source changed" toast
    /// immediately after load because reading the new book's pages updated
    /// their access-time, firing `.attrib`. The monitor must ignore attribute
    /// changes (chmod, xattr, atime) and only react to content edits, deletes,
    /// renames, or extends.
    @Test func chmodDoesNotTriggerCallback() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("page.png")
        try Fixture.makePNG(width: 10, height: 10).write(to: file)

        let recorder = CallbackRecorder()
        let monitor = SourceChangeMonitor()
        defer { monitor.stopWatching() }
        monitor.startWatching(url: file) {
            recorder.fire()
        }

        // chmod fires `.attrib`. With the bug present this would call the
        // callback; with the fix it must not.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )

        // The dispatch source delivers asynchronously. Give it a generous
        // quiet window; without `.attrib` in the mask there's nothing to
        // deliver and the count stays at zero.
        let final = await recorder.waitForCount(1, timeout: .milliseconds(300))
        #expect(final == 0)
    }

    @Test func writeDoesTriggerCallback() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("page.png")
        try Fixture.makePNG(width: 10, height: 10).write(to: file)

        let recorder = CallbackRecorder()
        let monitor = SourceChangeMonitor()
        defer { monitor.stopWatching() }
        monitor.startWatching(url: file) {
            recorder.fire()
        }

        // Truly modify content — this is the user-editing-a-file case.
        try Fixture.makePNG(width: 20, height: 20).write(to: file)

        let final = await recorder.waitForCount(1, timeout: .seconds(2))
        #expect(final >= 1)
    }

    /// After `stopWatching`, queued events from the previous session must not
    /// fire the new session's callback. The monitor stamps every handler with
    /// the session it was registered in and bails when the live session has
    /// moved past it — covers the race where a DispatchSource event was
    /// already enqueued on the global utility queue when we cancelled.
    @Test func staleHandlerFromPriorSessionDoesNotFireOldCallback() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("page.png")
        try Fixture.makePNG(width: 10, height: 10).write(to: file)

        let oldCallback = CallbackRecorder()
        let newCallback = CallbackRecorder()
        let monitor = SourceChangeMonitor()
        defer { monitor.stopWatching() }

        // Session 1: register old callback, immediately stop.
        monitor.startWatching(url: file) {
            oldCallback.fire()
        }
        monitor.stopWatching()

        // Session 2: register new callback, then mutate.
        monitor.startWatching(url: file) {
            newCallback.fire()
        }
        try Fixture.makePNG(width: 30, height: 30).write(to: file)

        let newFinal = await newCallback.waitForCount(1, timeout: .seconds(2))
        #expect(newFinal >= 1)
        #expect(oldCallback.count == 0)
    }
}

/// Records callback fires and lets tests wait for a target count with a
/// bounded timeout. Polling-based on purpose: a `CheckedContinuation` here
/// is leak-prone because `fire()` may arrive before the awaiter has stored
/// the continuation, and any timeout/cancellation path must not strand
/// a resumed-or-not continuation.
@MainActor
final class CallbackRecorder {
    private(set) var count = 0

    func fire() {
        count += 1
    }

    /// Polls `count` every 20 ms until it reaches `target` or `timeout`
    /// elapses. Always returns the final count — the caller decides whether
    /// hitting / missing the target is the failure.
    func waitForCount(_ target: Int, timeout: Duration) async -> Int {
        let deadline = ContinuousClock.now + timeout
        while count < target && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return count
    }
}
