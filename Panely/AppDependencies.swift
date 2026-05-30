import Foundation

nonisolated struct AppDependencies {
    let extractionCache: any ExtractionCacheManaging
    let bookmarkResolver: any SecurityScopedBookmarking
    let libraryTreeLoader: any LibraryTreeLoading
    let keyValueStore: any KeyValueStoring
    let systemSettings: any SystemSettingsReading
    let sourceChangeMonitorFactory: @MainActor () -> any SourceChangeMonitoring
    let libraryDirectoryWatcherFactory: @MainActor () -> any LibraryDirectoryWatching

    // Reader collaborators are surfaced as factories so tests can swap in
    // doubles without subclassing `ReaderViewModel`. The live implementations
    // capture the shared `keyValueStore` / `extractionCache` above, so the
    // collaborators all see the same persistence layer.
    let makeReaderPreferences: @MainActor () -> ReaderPreferences
    let makeReaderPositions: @MainActor () -> ReaderPositionStore
    let makeReadingProgress: @MainActor () -> ReadingProgressStore
    let makeReaderTempDirectory: @MainActor () -> ReaderTempDirectory

    static let live: AppDependencies = {
        let keyValueStore = LiveKeyValueStore()
        let extractionCache = LiveExtractionCacheManager()
        return AppDependencies(
            extractionCache: extractionCache,
            bookmarkResolver: LiveSecurityScopedBookmarkResolver(),
            libraryTreeLoader: LiveLibraryTreeLoader(),
            keyValueStore: keyValueStore,
            systemSettings: LiveSystemSettings(keyValueStore: keyValueStore),
            sourceChangeMonitorFactory: { SourceChangeMonitor() },
            libraryDirectoryWatcherFactory: { LiveLibraryDirectoryWatcher() },
            makeReaderPreferences: { ReaderPreferences(defaults: keyValueStore) },
            makeReaderPositions: { ReaderPositionStore(defaults: keyValueStore) },
            makeReadingProgress: { ReadingProgressStore(defaults: keyValueStore) },
            makeReaderTempDirectory: { ReaderTempDirectory(extractionCache: extractionCache) }
        )
    }()
}
