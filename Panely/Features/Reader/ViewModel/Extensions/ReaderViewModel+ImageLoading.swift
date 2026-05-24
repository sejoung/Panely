import AppKit
import Foundation

/// Thin facade over `ReaderImageLoader`. The real decode/preload/lazy-window
/// logic lives on the loader; this extension just feeds it the viewmodel's
/// current snapshot (source, layout, page index, epoch) and routes errors
/// back to `errorMessage`. Layout-change orchestration lives here too because
/// it bridges navigation state (snapping `currentPageIndex`) with the loader.
extension ReaderViewModel {

    // MARK: - Layout change orchestration

    func handleLayoutChange(from oldLayout: PageLayout) {
        // Only invoked from the `layout` forwarding setter on actual changes
        // (the setter diffs old vs. new before calling here), so no init-time
        // hydration guard is needed.
        let step = navigationStep
        currentPageIndex = (currentPageIndex / step) * step

        // Going from paged to vertical: clear stale paged images and show
        // a loading indicator immediately. Without this the user sees the
        // viewer's empty state for the duration of the dimension fetch +
        // initial window load (which can be a noticeable beat for big
        // folders). refreshImages clears isLoading when it finishes.
        if layout.isContinuous && !oldLayout.isContinuous {
            imageLoader.prepareForVerticalRebuild()
            isLoading = true
            loadingMessage = "Building vertical strip…"
        }
        Task { await refreshImages() }
    }

    // MARK: - Refresh dispatch

    func refreshImages() async {
        // Capture the load epoch so a refresh that finishes after a newer
        // load() has started doesn't clear the loading indicator on the
        // newer load's behalf. Layout-toggle refreshes don't bump the epoch,
        // so they'll clear normally.
        let epochAtStart = loadEpoch

        await imageLoader.refresh(
            source: source,
            layout: layout,
            currentPageIndex: currentPageIndex,
            navigationStep: navigationStep,
            isCancelled: { [weak self] in
                guard let self else { return true }
                return self.loadEpoch != epochAtStart
            },
            onError: { [weak self] message in
                AppLog.error(.image, message)
                self?.errorMessage = message
            }
        )

        // Always clear the loading flag when refresh completes — covers the
        // toggleLayout-driven path where handleLayoutChange set it to true.
        // load() also clears via its own defer; double-clear is harmless.
        if epochAtStart == loadEpoch {
            isLoading = false
            loadingMessage = ""
        }
    }

    // MARK: - Vertical-scroll-driven updates

    /// Sync the page index with the viewer's current scroll position in
    /// continuous (vertical) layouts. Just updates the page counter / saved
    /// position — actual loading is driven by `setVisibleRange(_:)` so that
    /// zoomed-out viewports get every visible slot loaded, not just ±radius
    /// around the center page.
    func setCurrentPageFromScroll(_ index: Int) {
        guard layout.isContinuous else { return }
        guard source.pages.indices.contains(index) else { return }
        guard index != currentPageIndex else { return }
        currentPageIndex = index
    }

    /// Called when the visible page range in the viewer changes (scroll or
    /// magnification). Loads every page in `range` plus a small buffer so
    /// pages just outside the viewport are ready when the user scrolls.
    /// Cancels any prior in-flight load so fast zoom/scroll doesn't pile
    /// up tasks all racing to finish. Also evicts pages outside the keep
    /// window so big strips don't pin every loaded image in memory.
    func setVisibleRange(_ range: Range<Int>) {
        imageLoader.setVisibleRange(
            range,
            source: source,
            layout: layout,
            onError: { [weak self] message in
                AppLog.error(.image, message)
                self?.errorMessage = message
            }
        )
    }
}
