import Foundation
import Observation
import Translation

/// App-wide record of Apple Translation language packs: which are installed
/// and which are downloading. Lives on `TranslationManager`, not in a view, so
/// "Downloading…" survives switching books and the panel, the status banner
/// and Settings all agree.
///
/// A download can only be asked for from a view (SwiftUI's `translationTask`,
/// see `TranslationPrimaryAction`), but once asked for it runs in the
/// system. Apple Translation reports no progress, so this polls until the
/// pack is installed — independent of the view that started it — and tells
/// `onInstalled`.
@Observable
@MainActor
final class LanguagePackDownloads {
    /// One language pair for one model; each model has its own packs.
    nonisolated struct Pack: Hashable, Sendable {
        let source: TranslationLanguage
        let target: TranslationLanguage
        let mode: TranslationMode

        init(source: TranslationLanguage, target: TranslationLanguage, mode: TranslationMode) {
            self.source = source
            self.target = target
            self.mode = mode.effective
        }
    }

    /// Last known status per pack; `nil` until looked up.
    private(set) var statuses: [Pack: TranslationLanguageStatus] = [:]
    /// Packs downloading, oldest first.
    private(set) var downloading: [Pack] = []
    /// A pack finished installing.
    @ObservationIgnored var onInstalled: ((Pack) -> Void)?
    @ObservationIgnored private var watchers: [Pack: Task<Void, Never>] = [:]

    func status(of pack: Pack) -> TranslationLanguageStatus? {
        statuses[pack]
    }

    func isDownloading(_ pack: Pack) -> Bool {
        watchers[pack] != nil
    }

    /// Look the pack up again — it may have been installed or removed in
    /// System Settings meanwhile.
    func refresh(_ pack: Pack) async {
        guard #available(macOS 26.0, *), !isDownloading(pack) else { return }
        let status = await TranslationAvailability.status(from: pack.source, to: pack.target, mode: pack.mode)
        guard !isDownloading(pack) else { return }
        statuses[pack] = status
    }

    /// The user asked for `pack`: show it as downloading until it's installed.
    func begin(_ pack: Pack) {
        guard #available(macOS 26.0, *), !isDownloading(pack) else { return }
        downloading.append(pack)
        watchers[pack] = Task { [weak self] in
            let status = await TranslationAvailability.statusAfterDownload(from: pack.source, to: pack.target, mode: pack.mode)
            guard !Task.isCancelled else { return }
            self?.finish(pack, status: status)
        }
    }

    /// The download didn't go ahead (declined in the system window, or failed).
    func failed(_ pack: Pack) async {
        watchers[pack]?.cancel()
        watchers[pack] = nil
        downloading.removeAll { $0 == pack }
        await refresh(pack)
    }

    private func finish(_ pack: Pack, status: TranslationLanguageStatus) {
        watchers[pack] = nil
        downloading.removeAll { $0 == pack }
        statuses[pack] = status
        if status == .installed { onInstalled?(pack) }
    }

    /// The body of a `translationTask` that downloads `pack`: shows Apple
    /// Translation's download window. The view may go away mid-download
    /// (another book opened); the download carries on and `begin`'s watcher
    /// keeps track of it.
    @available(macOS 26.0, *)
    nonisolated static func download(_ pack: Pack, using session: TranslationSession, into downloads: LanguagePackDownloads) async {
        do {
            try await session.prepareTranslation()
        } catch {
            guard !Task.isCancelled else { return }
            AppLog.error(.reader, "Translation language download failed", metadata: ["error": "\(error)"])
            await downloads.failed(pack)
        }
    }
}
