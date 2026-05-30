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
    private let delay: Duration

    init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    /// Run `action` after the delay, cancelling any still-pending one. The
    /// action captures its own `[weak self]` of the owning store, so a fired
    /// straggler after the owner is gone is a no-op.
    func schedule(_ action: @MainActor @escaping () -> Void) {
        task?.cancel()
        let delay = self.delay
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    /// Drop any pending action without running it. Callers that need an
    /// immediate write cancel here and then perform the write synchronously.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
