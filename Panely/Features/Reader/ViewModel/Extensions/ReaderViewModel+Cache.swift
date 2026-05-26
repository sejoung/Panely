import Foundation

extension ReaderViewModel {
    /// Clears the extraction cache (skipping the currently-open archive's temp
    /// dir) and presents the standard result alert. Used by the File menu and
    /// Storage settings — both routes get the same logging + UI behaviour.
    func clearExtractionCache() {
        let activeURL = tempDir.url
        let cacheMaintenance = CacheMaintenance(extractionCache: dependencies.extractionCache)
        AppLog.info(
            .cache,
            "Clear extraction cache requested",
            metadata: ["activeURL": "\(DiagnosticRedactor.describe(activeURL))"]
        )
        Task {
            let removedBytes = await Task.detached(priority: .utility) {
                cacheMaintenance.clearExtractionCache(excluding: activeURL)
            }.value
            cacheMaintenance.presentClearResult(removedBytes: removedBytes)
        }
    }
}
