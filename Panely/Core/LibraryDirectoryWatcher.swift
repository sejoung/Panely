import CoreServices
import Foundation

/// Watches a library root directory *recursively* and fires when anything
/// underneath it that the sidebar tree can show is added, removed or renamed
/// — the signal the sidebar uses to auto-refresh its file tree.
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

    /// What the stream's C callback needs, handed to it as the context
    /// `info`. The stream retains it through the context callbacks and
    /// releases it with the stream, so an in-flight callback never sees freed
    /// memory; `onEvent` holds the watcher weakly, so the stream can't keep
    /// the watcher alive.
    private nonisolated final class EventSink: Sendable {
        let filter: LibraryChangeFilter
        let onEvent: @Sendable () -> Void

        init(filter: LibraryChangeFilter, onEvent: @escaping @Sendable () -> Void) {
            self.filter = filter
            self.onEvent = onEvent
        }
    }

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

        let sink = EventSink(
            filter: LibraryChangeFilter(root: root, maxDepth: LibrarySidebarModel.deepScanDepth)
        ) { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleEvent() }
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<EventSink>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<EventSink>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        // Runs on `queue`. Filter here, off the main actor: only a batch
        // holding at least one change the tree could show is forwarded.
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let sink = Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue()
            // `kFSEventStreamCreateFlagUseCFTypes`: the paths are a CFArray
            // of CFStrings. Anything unreadable falls back to "relevant".
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths)
                .takeUnretainedValue() as NSArray as? [String]
            guard let paths, paths.count == count else {
                sink.onEvent()
                return
            }
            let flags = UnsafeBufferPointer(start: eventFlags, count: count)
            for (path, flag) in zip(paths, flags) where sink.filter.isRelevant(path: path, flags: flag) {
                sink.onEvent()
                return
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
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

/// Decides whether one FSEvents file event can change the sidebar tree,
/// which lists only folders and supported archives, skips hidden entries,
/// and stops `maxDepth` levels below the root. Everything else — Finder's
/// `.DS_Store` writes, sync daemons' temp files, page images deep inside a
/// book, rewrites of an archive's contents — is dropped instead of costing a
/// full rescan. Anything it can't classify counts as relevant.
nonisolated struct LibraryChangeFilter: Sendable {
    /// The root as given and with symlinks resolved: FSEvents reports real
    /// paths (`/private/var/…` for `/var/…`).
    let rootPaths: [String]
    let maxDepth: Int

    init(root: URL, maxDepth: Int) {
        let paths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]
            .map(Self.trimmingTrailingSlash)
        var seen: Set<String> = []
        self.rootPaths = paths.filter { seen.insert($0).inserted }
        self.maxDepth = maxDepth
    }

    func isRelevant(path: String, flags: FSEventStreamEventFlags) -> Bool {
        // Dropped / coalesced history, a moved or remounted root: the batch
        // can't be trusted to describe what changed.
        let rescanFlags = kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount
        if flags & FSEventStreamEventFlags(rescanFlags) != 0 { return true }

        let isFile = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        // Symlinks and unknown item kinds: don't guess.
        guard isFile != isDirectory,
              flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsSymlink) == 0,
              let components = relativeComponents(of: path),
              !components.isEmpty
        else { return true }

        // Below the deepest level the tree lists.
        if components.count > maxDepth { return false }
        // Hidden entries (and anything inside them) are skipped by the scan,
        // as are resource-fork folders.
        if components.contains(where: {
            $0.hasPrefix(".") || FolderResolver.ignoredDirectoryNames.contains(String($0))
        }) {
            return false
        }
        if isDirectory { return true }

        // A file only shows up as a supported archive, and only its
        // existence and name matter — not content or metadata rewrites.
        guard let name = components.last,
              ArchiveLoader.supportedExtensions.contains((name as NSString).pathExtension.lowercased())
        else { return false }
        let structural = kFSEventStreamEventFlagItemCreated
            | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed
        return flags & FSEventStreamEventFlags(structural) != 0
    }

    /// Path components below the root, or `nil` when `path` isn't under it
    /// (then the caller rescans to be safe). `[]` for the root itself.
    private func relativeComponents(of path: String) -> [Substring]? {
        let trimmed = Self.trimmingTrailingSlash(path)
        for root in rootPaths {
            if trimmed == root { return [] }
            let prefix = root == "/" ? root : root + "/"
            guard trimmed.hasPrefix(prefix) else { continue }
            return trimmed.dropFirst(prefix.count).split(separator: "/")
        }
        return nil
    }

    private static func trimmingTrailingSlash(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
