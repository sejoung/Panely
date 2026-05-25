import Darwin
import Foundation

@MainActor
protocol SourceChangeMonitoring: AnyObject {
    func startWatching(url: URL, onChange: @MainActor @escaping () -> Void)
    func stopWatching()
}

@MainActor
final class SourceChangeMonitor: SourceChangeMonitoring {
    private var source: DispatchSourceFileSystemObject?
    private var hasReportedChange = false

    deinit {
        source?.cancel()
    }

    func startWatching(url: URL, onChange: @MainActor @escaping () -> Void) {
        stopWatching()

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

        hasReportedChange = false

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
        self.source = source
        source.resume()
    }

    func stopWatching() {
        source?.cancel()
        source = nil
        hasReportedChange = false
    }
}
