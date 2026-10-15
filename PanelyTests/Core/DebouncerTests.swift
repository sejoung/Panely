import Testing
@testable import Panely

/// The debouncer is the one place real time matters; the stores and the
/// library watcher that use it flush it in their tests instead of waiting.
/// A short delay keeps these quick, and only "it fires by itself" waits.
@MainActor
struct DebouncerTests {
    @Test func rapidCallsCoalesceIntoTheLastAction() async throws {
        let debouncer = Debouncer(delay: .milliseconds(20))
        var ran: [Int] = []

        for value in 1...3 {
            debouncer.schedule { ran.append(value) }
        }
        #expect(ran.isEmpty)
        #expect(debouncer.isPending)

        try await waitUntil { !ran.isEmpty }
        #expect(ran == [3])
        #expect(!debouncer.isPending)
    }

    @Test func flushRunsThePendingActionNowAndOnce() async throws {
        let debouncer = Debouncer(delay: .milliseconds(20))
        var count = 0
        debouncer.schedule { count += 1 }

        debouncer.flush()
        #expect(count == 1)
        #expect(!debouncer.isPending)

        // The cancelled timer doesn't run it a second time.
        try await Task.sleep(for: .milliseconds(60))
        #expect(count == 1)
    }

    @Test func cancelDropsThePendingAction() {
        let debouncer = Debouncer(delay: .milliseconds(20))
        var count = 0
        debouncer.schedule { count += 1 }

        debouncer.cancel()
        debouncer.flush()

        #expect(count == 0)
        #expect(!debouncer.isPending)
    }
}
