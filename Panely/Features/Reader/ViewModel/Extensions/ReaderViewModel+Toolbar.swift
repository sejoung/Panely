import Foundation

/// The toolbar's language menus for one set of inputs. Localizing every
/// language name on every toolbar render would otherwise repeat on each page
/// turn while the toolbar is up, for lists that almost never change.
struct ToolbarLanguagesMemo {
    struct Inputs: Equatable {
        let locale: Locale
        let listed: [TranslationLanguage]
        let source: TranslationLanguage?
        let suggested: TranslationLanguage?
    }
    let inputs: Inputs
    let languages: [ToolbarTranslationState.Language]
    let suggestedLanguage: ToolbarTranslationState.Language?
    let otherLanguages: [ToolbarTranslationState.Language]
}

extension ReaderViewModel {
    /// Snapshot of the fields `PanelyToolbar` reads. Computed each render so
    /// the toolbar always reflects current viewmodel state — adding a new
    /// toolbar control means adding a field here and on `PanelyToolbarState`,
    /// not threading another parameter through `ReaderToolbarOverlay`.
    ///
    /// `isAtFit` lives on `ViewerController` (it tracks AppKit-side scroll
    /// magnification), so the overlay supplies it. Defaults to `true` so the
    /// viewmodel-only callsites get the historical "highlight the current
    /// fit" behaviour without needing a viewer reference.
    func toolbarState(isAtFit: Bool = true) -> PanelyToolbarState {
        PanelyToolbarState(
            layout: layout,
            direction: direction,
            fitMode: fitMode,
            sidebarPinned: sidebarPinned,
            autoFitOnResize: autoFitOnResize,
            toolbarPinned: toolbarPinned,
            showVolumeNav: hasMultipleVolumes || volumeNavigationNeedsFolderAccess,
            canGoPreviousVolume: canStepToPreviousVolume,
            canGoNextVolume: canStepToNextVolume,
            hasSource: hasSource,
            isBookFavorite: isCurrentBookFavorite,
            isPageBookmarked: isCurrentPageBookmarked,
            thumbnailSidebarVisible: thumbnailSidebarVisible,
            doublePageCoverAlone: doublePageCoverAlone,
            isAtFit: isAtFit,
            pageBookmarks: currentBookPageBookmarks,
            visiblePageRange: currentSpread,
            canGoPreviousBookmark: canGoPreviousBookmark,
            canGoNextBookmark: canGoNextBookmark,
            otherBookmarkedBooks: otherBookmarkedBooks,
            translation: toolbarTranslationState
        )
    }

    private var toolbarTranslationState: ToolbarTranslationState? {
        guard translationFeatureAvailable else { return nil }
        let locale = localization.locale
        let listed = translationLanguagesWithResults.map(\.target)
        let source = translationSourceLanguage
        let display = translationDisplayLanguage
        let suggested = listed.contains(display) || display == source ? nil : display
        let menus = toolbarLanguages(
            for: .init(locale: locale, listed: listed, source: source, suggested: suggested)
        )
        return ToolbarTranslationState(
            showsTranslation: translationIsShowing,
            isWorking: translationManager.openBook.contains(where: \.isWorking),
            hasTranslations: translation.hasPages,
            shownLanguage: translationDisplayLanguage,
            shownLanguageName: translationDisplayLanguage.displayName(in: locale),
            languages: menus.languages,
            suggestedLanguage: menus.suggestedLanguage,
            otherLanguages: menus.otherLanguages,
            isEditing: isEditingTranslations,
            canEdit: canEditTranslations,
            canTranslateAgain: canTranslateAgain && !translation.isWorking,
            canImproveWithAIChat: canImproveWithAIChat,
            canExport: canExportCurrentBook,
            canExportSeries: canExportCurrentBook && !translatableSeriesVolumes.isEmpty
        )
    }

    private func toolbarLanguages(for inputs: ToolbarLanguagesMemo.Inputs) -> ToolbarLanguagesMemo {
        if let memo = toolbarLanguagesMemo, memo.inputs == inputs { return memo }
        func entry(_ language: TranslationLanguage) -> ToolbarTranslationState.Language {
            ToolbarTranslationState.Language(language: language, name: language.displayName(in: inputs.locale))
        }
        let memo = ToolbarLanguagesMemo(
            inputs: inputs,
            languages: inputs.listed.map(entry),
            suggestedLanguage: inputs.suggested.map(entry),
            otherLanguages: TranslationLanguage.allCases
                .filter { !inputs.listed.contains($0) && $0 != inputs.source && $0 != inputs.suggested }
                .map(entry)
        )
        toolbarLanguagesMemo = memo
        return memo
    }

    /// Builds the toolbar action bundle. Zoom routes through `ViewerController`
    /// (which owns the AppKit scroll view), so it has to be passed in — the
    /// viewmodel doesn't know about that layer.
    func toolbarActions(viewerController: ViewerController) -> PanelyToolbarActions {
        PanelyToolbarActions(
            onOpen: { [self] in openSource() },
            onPrev: { [self] in previous() },
            onNext: { [self] in next() },
            onSetLayout: { [self] in setLayout($0) },
            onToggleDirection: { [self] in toggleDirection() },
            onSetFitMode: { [self] target in
                // Picking a *different* fit mode goes through the viewmodel —
                // the fitMode prop change drives `applyFit` with `force=true`
                // via the AppKit diff. Re-pressing the *same* fit mode would
                // be a viewmodel no-op (the value didn't change), so route
                // it through `resetZoom` instead — that's the user saying
                // "I'm done zooming, snap me back to fit."
                if fitMode == target {
                    viewerController.resetZoom()
                } else {
                    setFitMode(target)
                }
            },
            onToggleSidebarPin: { [self] in toggleSidebarPin() },
            onZoomIn: { viewerController.zoomIn() },
            onZoomOut: { viewerController.zoomOut() },
            onToggleAutoFit: { [self] in toggleAutoFitOnResize() },
            onToggleToolbarPin: { [self] in toggleToolbarPin() },
            onPreviousVolume: { [self] in stepToPreviousVolume() },
            onNextVolume: { [self] in stepToNextVolume() },
            onToggleFavorite: { [self] in toggleFavoriteForCurrentBook() },
            onTogglePageBookmark: { [self] in toggleCurrentPageBookmark() },
            onToggleThumbnailSidebar: { [self] in toggleThumbnailSidebar() },
            onToggleDoublePageCoverAlone: { [self] in toggleDoublePageCoverAlone() },
            onJumpToBookmark: { [self] in jumpToBookmark($0) },
            onPreviousBookmark: { [self] in jumpToPreviousBookmark() },
            onNextBookmark: { [self] in jumpToNextBookmark() },
            onOpenBookmark: { [self] bookmark, book in openBookmark(bookmark, in: book) },
            onRemoveAllPageBookmarks: { [self] in BookmarkAlerts.removeAllInCurrentBook(self) },
            onToggleTranslation: { [self] in toggleTranslationOverlay() },
            onShowOriginal: { [self] in showOriginal() },
            onShowTranslation: { [self] in showTranslation(in: $0) },
            onToggleTranslationEditing: { [self] in toggleEditingTranslations() },
            onTranslateInto: { [self] language in
                showTranslation(in: language)
                startTranslating(into: language)
            },
            onTranslatePageAgain: { [self] in translateCurrentPagesAgain() },
            onImproveWithAIChat: { [self] in requestAIChat() },
            onExportBook: { [self] in requestExportOfCurrentBook() },
            onExportSeries: { [self] in requestExportOfCurrentSeries() }
        )
    }
}
