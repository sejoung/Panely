import Foundation

nonisolated protocol SecurityScopedResourceAccessing {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

private nonisolated struct URLSecurityScopedResourceAccessor: SecurityScopedResourceAccessing {
    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Owns the macOS sandbox security-scoped resource grant for the current
/// library root. The reader can only read files inside a URL the user
/// explicitly picked (Open dialog, drag-drop, "Open With"); macOS hands us
/// a transient grant on that URL which must be `startAccessingSecurityScopedResource`'d
/// before any I/O and `stop…`'d when we're done with it. Letting the grant
/// outlive its usefulness leaks a kernel-side reference; releasing it too
/// early breaks subsequent reads (silent permission failures).
///
/// Centralising the lifecycle here means the load pipeline doesn't sprinkle
/// `rootScopedURL?.stopAccessingSecurityScopedResource()` calls across error
/// paths and book-switch branches, and ensures `isInside(...)` checks always
/// reflect the active grant.
@MainActor
final class ReaderLibraryScope {
    /// Currently scoped URL, or `nil` when no grant is held. Direct
    /// assignment is supported for tests that need to inject a URL without
    /// going through Powerbox; production code should always go through
    /// `acquire(_:)` / `release()` so the kernel-side grant lifecycle stays
    /// paired.
    var url: URL?
    private let accessor: any SecurityScopedResourceAccessing
    private var hasStartedSecurityScope = false

    init(accessor: any SecurityScopedResourceAccessing = URLSecurityScopedResourceAccessor()) {
        self.accessor = accessor
    }

    /// True when a security-scope grant is currently held.
    var isActive: Bool { url != nil }

    /// Replace any current grant with one on `candidate`. Returns `true` on
    /// success. On failure the previous grant is already released — callers
    /// should treat it as "no scope held" and decide whether to surface an
    /// error or proceed without sandboxed access (some test/dev paths read
    /// from non-scoped locations).
    @discardableResult
    func acquire(_ candidate: URL) -> Bool {
        release()
        if accessor.startAccessing(candidate) {
            url = candidate
            hasStartedSecurityScope = true
            return true
        }
        return false
    }

    /// Release the active grant (if any). No-op when nothing is held.
    func release() {
        if hasStartedSecurityScope, let url {
            accessor.stopAccessing(url)
        }
        url = nil
        hasStartedSecurityScope = false
    }

    /// True when `candidate` lives at or under the scoped URL. False when no
    /// scope is active — caller should treat that as "out of tree" and
    /// trigger a re-acquire.
    func contains(_ candidate: URL) -> Bool {
        guard let root = url else { return false }
        return root.isAncestor(of: candidate)
    }
}
