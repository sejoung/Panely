import Darwin
import Foundation

@MainActor
protocol SourceChangeMonitoring: AnyObject {
    func startWatching(url: URL, onChange: @MainActor @escaping () -> Void)
    func startWatching(urls: [URL], onChange: @MainActor @escaping () -> Void)
    func stopWatching()
}

@MainActor
final class SourceChangeMonitor: SourceChangeMonitoring {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var hasReportedChange = false
    /// Bumped on every `startWatching` (and `stopWatching`). Event handlers
    /// capture the value live at fire time and bail if it's moved — covers
    /// the race where a DispatchSource event was already queued for the
    /// global utility queue when we cancel, then drains onto MainActor
    /// after the next session has started.
    private var session: UInt = 0

    deinit {
        for source in sources {
            source.cancel()
        }
    }

    func startWatching(url: URL, onChange: @MainActor @escaping () -> Void) {
        startWatching(urls: [url], onChange: onChange)
    }

    func startWatching(urls: [URL], onChange: @MainActor @escaping () -> Void) {
        stopWatching()

        let uniqueURLs = Array(Set(urls.map(\.standardizedFileURL)))
        guard !uniqueURLs.isEmpty else { return }

        session &+= 1
        let mySession = session
        hasReportedChange = false

        for url in uniqueURLs {
            watch(url: url, session: mySession, onChange: onChange)
        }
    }

    private func watch(
        url: URL,
        session expectedSession: UInt,
        onChange: @MainActor @escaping () -> Void
    ) {
        let standardized = url.standardizedFileURL
        let descriptor = open(standardized.path, O_EVTONLY)
        guard descriptor >= 0 else {
            AppLog.warning(
                .reader,
                "Source change monitor unavailable",
                metadata: ["source": "\(DiagnosticRedactor.describe(standardized))"]
            )
            return
        }

        // `.attrib` is intentionally excluded: it fires on access-time and
        // xattr updates, which the app itself triggers every time it reads
        // a page (and which Spotlight / Time Machine / Finder previews can
        // bump unrelatedly). We only care about real content changes —
        // `.write` / `.extend` cover edits, `.delete` / `.rename` cover
        // moves and removals. Folder URLs surface adds/removes via the
        // directory's own `.write` when its listing changes.
        let eventMask: DispatchSource.FileSystemEvent = [
            .write,
            .delete,
            .rename,
            .extend,
        ]
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: eventMask,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.session == expectedSession,
                      !self.hasReportedChange else { return }
                self.hasReportedChange = true
                AppLog.info(
                    .reader,
                    "Source changed on disk",
                    metadata: ["source": "\(DiagnosticRedactor.describe(standardized))"]
                )
                onChange()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        sources.append(source)
        source.resume()
    }

    func stopWatching() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
        session &+= 1
        hasReportedChange = false
    }
}
