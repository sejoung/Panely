import CoreServices
import Foundation

/// Watches a library root directory *recursively* and fires when anything
/// underneath it is added, removed, renamed, or modified — the signal the
/// sidebar uses to auto-refresh its file tree.
///
/// Distinct from `SourceChangeMonitor`, which watches a fixed list of the
/// *open book's* files non-recursively (a `DispatchSource` vnode per URL).
/// A whole-subtree watch is a different job: FSEvents is the right tool —
/// one stream covers the entire tree, the kernel coalesces bursts, and the
/// `latency` argument debounces for free.
@MainActor
protocol LibraryDirectoryWatching: AnyObject {
    func startWatching(root: URL, onChange: @MainActor @escaping () -> Void)
    func stopWatching()
}

@MainActor
final class LiveLibraryDirectoryWatcher: LibraryDirectoryWatching {
    private var stream: FSEventStreamRef?
    private var onChange: (@MainActor () -> Void)?
    private let queue = DispatchQueue(
        label: "io.github.sejoung.Panely.library-watcher",
        qos: .utility
    )

    /// Coalescing window. FSEvents batches all change notifications that land
    /// within this interval into a single callback, so a bulk copy of 500
    /// files fires roughly once per second rather than 500 times.
    private static let latency: CFTimeInterval = 1.0

    deinit {
        // `deinit` is nonisolated; tear the C stream down inline (FSEvents
        // APIs are thread-agnostic and we touch no actor-isolated state).
        // The VM stops the watcher on book-clear / root-change, so this only
        // matters for the process-teardown path.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func startWatching(root: URL, onChange: @MainActor @escaping () -> Void) {
        stopWatching()
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            // Unretained: `self` owns the stream, and `stopWatching()`/`deinit`
            // invalidate it before `self` goes away, so no callback can
            // dereference freed memory in normal operation. A retained `info`
            // would form a self↔stream cycle that never deallocates.
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LiveLibraryDirectoryWatcher>
                .fromOpaque(info)
                .takeUnretainedValue()
            Task { @MainActor in watcher.handleEvent() }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagIgnoreSelf
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        ) else {
            AppLog.warning(
                .library,
                "Library directory watcher unavailable",
                metadata: ["source": "\(DiagnosticRedactor.describe(root))"]
            )
            self.onChange = nil
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        AppLog.info(
            .library,
            "Library directory watch started",
            metadata: ["source": "\(DiagnosticRedactor.describe(root))"]
        )
    }

    func stopWatching() {
        onChange = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handleEvent() {
        // `onChange` is cleared by `stopWatching()`, so a callback that was
        // already in flight when we tore down resolves to a no-op here.
        onChange?()
    }
}
