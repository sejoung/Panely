import Foundation

/// Coalesces rapid calls into a single trailing action after a quiet period.
///
/// Extracted from the persistence stores, which each hand-rolled the same
/// `cancel + Task.sleep + guard` dance to debounce `UserDefaults` writes during
/// high-frequency events (vertical scroll fires a position save on every page
/// change at ~60 Hz).
@MainActor
final class Debouncer {
    private var task: Task<Void, Never>?
    private var pending: (@MainActor () -> Void)?
    private let delay: Duration

    init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    /// Run `action` after the delay, cancelling any still-pending one. The
    /// action captures its own `[weak self]` of the owning store, so a fired
    /// straggler after the owner is gone is a no-op.
    func schedule(_ action: @MainActor @escaping () -> Void) {
        task?.cancel()
        pending = action
        let delay = self.delay
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Run the pending action now instead of waiting out the delay. Used when
    /// the next write is for a *different* record: replacing the pending
    /// action would otherwise silently drop the previous record's last write.
    func flush() {
        let action = pending
        cancel()
        action?()
    }

    /// Drop any pending action without running it. Callers that need an
    /// immediate write cancel here and then perform the write synchronously.
    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}
