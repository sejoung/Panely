import Foundation

nonisolated struct AppDependencies {
    let extractionCache: any ExtractionCacheManaging
    let bookmarkResolver: any SecurityScopedBookmarking
    let libraryTreeLoader: any LibraryTreeLoading
    let keyValueStore: any KeyValueStoring
    let systemSettings: any SystemSettingsReading
    let sourceChangeMonitorFactory: @MainActor () -> any SourceChangeMonitoring

    static let live: AppDependencies = {
        let keyValueStore = LiveKeyValueStore()
        return AppDependencies(
            extractionCache: LiveExtractionCacheManager(),
            bookmarkResolver: LiveSecurityScopedBookmarkResolver(),
            libraryTreeLoader: LiveLibraryTreeLoader(),
            keyValueStore: keyValueStore,
            systemSettings: LiveSystemSettings(keyValueStore: keyValueStore),
            sourceChangeMonitorFactory: { SourceChangeMonitor() }
        )
    }()
}
