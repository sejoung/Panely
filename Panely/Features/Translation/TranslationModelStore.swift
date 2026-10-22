import Foundation
import Observation

/// App-wide state of the translation model: downloaded or not, and the
/// download in progress. Lives on `TranslationManager`, so the panel, the
/// status banner and Settings all show the same download, and it carries on
/// while books are switched.
///
/// The download is 3.3 GB. It goes to a staging file next to the model, is
/// checked against the pinned size and hash (`TranslationModelFiles.install`)
/// and only then moved into place; a failed or damaged download never leaves
/// a model that looks installed.
@Observable
@MainActor
final class TranslationModelStore {
    nonisolated enum State: Equatable, Sendable {
        case notInstalled
        case downloading(received: Int64, total: Int64)
        /// Downloaded; checking the hash (a few seconds for 3.3 GB).
        case verifying
        case installed
        case failed(String)
    }

    private(set) var state: State
    let files: TranslationModelFiles
    /// The model was installed — jobs waiting for it start again.
    @ObservationIgnored var onInstalled: (() -> Void)?
    @ObservationIgnored private let downloader: any TranslationModelDownloading
    @ObservationIgnored private var task: Task<Void, Never>?
    /// When progress was last published: the delegate reports every few
    /// kilobytes, far more often than anyone can see.
    @ObservationIgnored private var lastProgress: ContinuousClock.Instant?

    init(files: TranslationModelFiles = TranslationModelFiles(), downloader: any TranslationModelDownloading = URLSessionModelDownloader()) {
        self.files = files
        self.downloader = downloader
        state = files.isInstalled ? .installed : .notInstalled
    }

    var model: TranslationModel { files.model }
    var isInstalled: Bool { state == .installed }

    var isDownloading: Bool {
        switch state {
        case .downloading, .verifying: true
        case .notInstalled, .installed, .failed: false
        }
    }

    /// 0…1 while downloading.
    var fractionDownloaded: Double? {
        guard case let .downloading(received, total) = state, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    /// Look at the disk again (removed by hand, say).
    func refresh() {
        guard !isDownloading else { return }
        state = files.isInstalled ? .installed : .notInstalled
    }

    func download() {
        guard !isDownloading, !files.isInstalled else {
            refresh()
            return
        }
        let files = files
        let downloader = downloader
        let staging = files.root.appendingPathComponent("\(files.model.id).download")
        state = .downloading(received: 0, total: files.model.bytes)
        lastProgress = nil
        AppLog.info(.reader, "Translation model download started", metadata: ["model": "\(files.model.id)"])
        task = Task { [weak self] in
            // Progress arrives on the download's own queue; only the latest
            // matters.
            let (updates, sink) = AsyncStream.makeStream(of: (Int64, Int64).self, bufferingPolicy: .bufferingNewest(1))
            let watcher = Task { [weak self] in
                for await (received, total) in updates {
                    self?.progress(received: received, total: total)
                }
            }
            defer {
                sink.finish()
                watcher.cancel()
            }
            do {
                try FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true)
                try await downloader.download(from: files.model.url, to: staging) { received, total in
                    sink.yield((received, total))
                }
                try Task.checkCancellation()
                self?.state = .verifying
                try await Task.detached(priority: .utility) {
                    defer { try? FileManager.default.removeItem(at: staging) }
                    try files.install(downloadedFile: staging)
                }.value
                try Task.checkCancellation()
                self?.finish(.installed)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                AppLog.error(.reader, "Translation model download failed", metadata: ["error": "\(error)"])
                self?.finish(.failed(error.localizedDescription))
            }
        }
    }

    func cancelDownload() {
        task?.cancel()
        task = nil
        state = files.isInstalled ? .installed : .notInstalled
    }

    /// Delete the model (Settings). Returns the bytes freed.
    @discardableResult
    func remove() async -> Int64 {
        cancelDownload()
        let files = files
        let freed = await Task.detached(priority: .utility) { files.remove() }.value
        state = .notInstalled
        return freed
    }

    private func progress(received: Int64, total: Int64) {
        guard case .downloading = state else { return }
        let now = ContinuousClock.now
        if let lastProgress, received < total, lastProgress.duration(to: now) < .milliseconds(250) { return }
        lastProgress = now
        state = .downloading(received: received, total: total > 0 ? total : files.model.bytes)
    }

    private func finish(_ state: State) {
        task = nil
        self.state = state
        if state == .installed {
            AppLog.info(.reader, "Translation model installed", metadata: ["model": "\(files.model.id)"])
            onInstalled?()
        }
    }
}

/// Fetches the model file. Tests swap in one that writes a small file.
nonisolated protocol TranslationModelDownloading: Sendable {
    /// Download `url` to `destination` (replacing it), reporting bytes
    /// received and expected as it goes. Cancelling the task stops it.
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}

/// A plain `URLSession` download, its own session per file so the delegate
/// sees only its own progress.
nonisolated struct URLSessionModelDownloader: TranslationModelDownloading {
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let run = DownloadRun(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: run, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                run.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private nonisolated final class DownloadRun: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Int64, Int64) -> Void
    /// Set before the task starts; the delegate queue resumes it once.
    var continuation: CheckedContinuation<Void, any Error>?
    private var moveError: (any Error)?

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    /// The system deletes `location` when this returns, so it's moved now.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            moveError = URLError(.badServerResponse)
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error = error ?? moveError {
            continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
