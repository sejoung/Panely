import Foundation

/// Commits whole-store snapshots to `UserDefaults`, on or off the main thread,
/// where the newest generation always wins.
///
/// The stores write a full snapshot each time. Once some of those are encoded
/// in the background, a slow encode could otherwise finish after a later
/// synchronous write — the flush at app termination, say — and put older data
/// back on top of it.
nonisolated final class LatestWinsDefaultsWriter: @unchecked Sendable {
    private let defaults: any KeyValueStoring
    private let lock = NSLock()
    private var committed = 0

    init(defaults: any KeyValueStoring) {
        self.defaults = defaults
    }

    /// `values` runs outside the lock, so a background encode never makes a
    /// synchronous commit wait for it; `nil` means there is nothing to write.
    func commit(generation: Int, _ values: () -> [String: any Sendable]?) {
        guard !hasCommitted(generation), let values = values() else { return }
        lock.withLock {
            guard generation > committed else { return }
            for (key, value) in values {
                defaults.set(value, forKey: key)
            }
            committed = generation
        }
    }

    func commitInBackground(
        generation: Int,
        _ values: @escaping @Sendable () -> [String: any Sendable]?
    ) {
        Task.detached(priority: .utility) { [self] in
            commit(generation: generation, values)
        }
    }

    /// `generation` (or a newer one) has reached the defaults.
    func hasCommitted(_ generation: Int) -> Bool {
        lock.withLock { committed >= generation }
    }
}
