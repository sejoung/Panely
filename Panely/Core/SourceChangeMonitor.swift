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

        hasReportedChange = false

        for url in uniqueURLs {
            watch(url: url, onChange: onChange)
        }
    }

    private func watch(url: URL, onChange: @MainActor @escaping () -> Void) {
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

        let eventMask: DispatchSource.FileSystemEvent = [
            .write,
            .delete,
            .rename,
            .extend,
            .attrib,
        ]
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: eventMask,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.hasReportedChange else { return }
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
        hasReportedChange = false
    }
}
