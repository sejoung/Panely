import Foundation

nonisolated struct AppDependencies {
    let extractionCache: any ExtractionCacheManaging
    let bookmarkResolver: any SecurityScopedBookmarking
    let libraryTreeLoader: any LibraryTreeLoading
    let keyValueStore: any KeyValueStoring
    let systemSettings: any SystemSettingsReading
    let sourceChangeMonitorFactory: @MainActor () -> any SourceChangeMonitoring
    let libraryDirectoryWatcherFactory: @MainActor () -> any LibraryDirectoryWatching
    /// Master switch for FSEvents-driven sidebar auto-refresh. Enabled in
    /// production after the tree refresh path was debounced and verified on
    /// Release builds; tests and previews can still disable it.
    let libraryAutoRefreshEnabled: Bool
    let filePickerFactory: @MainActor () -> any FilePicking
    /// Which language the UI is in. Live: the process-wide instance behind
    /// `Bundle.localized`. Tests get their own so switching languages in one
    /// test can't leak into another's strings.
    let localization: AppLocalization
    /// On-disk cache for the translation assist. Tests point it at a temp dir.
    let translationStore: TranslationStore
    /// The reader's balloon edits. Tests point it at a temp dir.
    let translationEditStore: TranslationEditStore
    /// Translates the balloons (Gemma, `GemmaTranslator`). Tests get
    /// stand-ins, so they never load the model.
    let translator: any BalloonTranslating
    /// The translation model's download state. Tests point it at a temp dir.
    let makeTranslationModelStore: @MainActor () -> TranslationModelStore
    /// Reads balloons off pages for translation jobs; `nil` is OCR. Tests
    /// hand jobs their balloons through this.
    let makePageAnalyzer: (@Sendable ([ComicPage], TranslationLanguage) -> any PageAnalyzing)?

    // Reader collaborators are surfaced as factories so tests can swap in
    // doubles without subclassing `ReaderViewModel`. The live implementations
    // capture the shared `keyValueStore` / `extractionCache` above, so the
    // collaborators all see the same persistence layer.
    let makeReaderPreferences: @MainActor () -> ReaderPreferences
    let makeReaderPositions: @MainActor () -> ReaderPositionStore
    let makeReadingProgress: @MainActor () -> ReadingProgressStore
    let makeLastLibraryRoot: @MainActor () -> LastLibraryRootStore
    let makeReaderTempDirectory: @MainActor () -> ReaderTempDirectory
    let makeReaderLibraryScope: @MainActor () -> ReaderLibraryScope

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
            libraryAutoRefreshEnabled: true,
            filePickerFactory: { LiveFilePicker() },
            localization: .shared,
            translationStore: TranslationStore(),
            translationEditStore: TranslationEditStore(),
            translator: GemmaTranslator.shared,
            makeTranslationModelStore: { TranslationModelStore(files: GemmaTranslator.shared.files) },
            makePageAnalyzer: nil,
            makeReaderPreferences: { ReaderPreferences(defaults: keyValueStore) },
            makeReaderPositions: { ReaderPositionStore(defaults: keyValueStore) },
            makeReadingProgress: { ReadingProgressStore(defaults: keyValueStore) },
            makeLastLibraryRoot: { LastLibraryRootStore(defaults: keyValueStore) },
            makeReaderTempDirectory: { ReaderTempDirectory(extractionCache: extractionCache) },
            makeReaderLibraryScope: { ReaderLibraryScope() }
        )
    }()
}
