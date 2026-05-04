import Foundation

/// Page-level navigation, Quick-jump helpers, and chrome toggles (layout /
/// direction / fit / sidebar / toolbar / thumbnail). All main-actor isolated
/// by the class annotation.
extension ReaderViewModel {

    // MARK: - Visible page span

    var visiblePages: [ComicPage] {
        if layout.isContinuous {
            return source.pages
        }
        let start = currentPageIndex
        guard source.pages.indices.contains(start) else { return [] }
        let end = min(start + navigationStep, source.pageCount)
        return Array(source.pages[start..<end])
    }

    var pageCounterLabel: String {
        guard !source.isEmpty else { return "" }
        let count = totalPages
        let first = currentPageIndex + 1
        let last = min(currentPageIndex + navigationStep, count)
        return first == last ? "\(first) / \(count)" : "\(first)-\(last) / \(count)"
    }

    /// 1-indexed first page in the currently visible span.
    var currentPageNumber: Int {
        source.isEmpty ? 0 : currentPageIndex + 1
    }

    /// 1-indexed last page in the currently visible span. Matches
    /// `currentPageNumber` outside double-page mode.
    var currentPageRangeEndNumber: Int {
        guard !source.isEmpty else { return 0 }
        return min(currentPageIndex + navigationStep, totalPages)
    }

    // MARK: - Page navigation

    func next() {
        let target = currentPageIndex + navigationStep
        guard target < source.pageCount else { return }
        currentPageIndex = target
        scheduleRefreshIfPaged()
    }

    /// Forward action for keyboard / space-bar handlers. When the
    /// end-of-volume card is showing, the user has already seen the cue, so
    /// pressing forward advances to the next sibling instead of no-oping.
    /// Toolbar buttons keep `next()` / `nextVolume()` separate so users can
    /// page within the final spread without auto-jumping books.
    func advanceForward() {
        if showsEndOfVolumeCard {
            nextVolume()
        } else {
            next()
        }
    }

    /// Backward action for keyboard handlers. Asymmetric with
    /// `advanceForward()` because the prev-volume card is gated behind an
    /// explicit signal (this method) — without that, opening any volume on
    /// page 0 would auto-prompt about the previous one.
    ///
    /// Behavior at page 0:
    ///   - first press     → arms the cue (`wantsPreviousVolumePrompt = true`)
    ///   - second press    → loads the previous sibling
    ///
    /// Behavior elsewhere:
    ///   - pages backward via `previous()`. If that lands on page 0 with a
    ///     previous sibling, the cue is armed automatically so the next
    ///     press advances volumes — mirroring how the forward card auto-
    ///     appears on reaching the last page.
    func goBackward() {
        if currentPageIndex == 0 {
            guard canGoPreviousVolume else { return }
            if wantsPreviousVolumePrompt {
                previousVolume()
            } else {
                wantsPreviousVolumePrompt = true
            }
            return
        }

        let target = currentPageIndex - navigationStep
        let willLandOnZero = target <= 0
        previous()
        // `previous()` triggers the didSet that resets the cue. If we just
        // landed on page 0 with a prev sibling, re-arm so the user's next
        // press advances volumes without a wasted no-op press first.
        if willLandOnZero && canGoPreviousVolume {
            wantsPreviousVolumePrompt = true
        }
    }

    func previous() {
        let target = currentPageIndex - navigationStep
        guard target >= 0 else {
            guard currentPageIndex > 0 else { return }
            currentPageIndex = 0
            scheduleRefreshIfPaged()
            return
        }
        currentPageIndex = target
        scheduleRefreshIfPaged()
    }

    func jump(to index: Int) {
        let step = navigationStep
        let snapped = (index / step) * step
        let clamped = min(max(snapped, 0), max(0, source.pageCount - 1))
        guard clamped != currentPageIndex else { return }
        currentPageIndex = clamped
        scheduleRefreshIfPaged()
    }

    /// Jump to a 1-indexed page number. Clamps silently, so callers can pass
    /// user input without pre-validation.
    func jump(toPageNumber pageNumber: Int) {
        guard totalPages > 0 else { return }
        let clamped = min(max(pageNumber, 1), totalPages)
        jump(to: clamped - 1)
    }

    /// In continuous (vertical) layouts the entire strip is already loaded,
    /// so paging just means scrolling — no need to re-iterate every page
    /// through ImageLoader on every keystroke.
    func scheduleRefreshIfPaged() {
        guard !layout.isContinuous else { return }
        Task { await refreshImages() }
    }

    // MARK: - Chrome toggles

    func toggleLayout() {
        // Don't auto-change fitMode on layout transitions — the user's last
        // explicit fit choice is preserved. If they want a different fit
        // for the new mode they can press ⌘1/⌘2/⌘3. Combined with applyFit
        // not force-resetting magnification on layout-only changes, this
        // means a manually-zoomed viewer stays at that zoom across modes.
        layout = layout.next
    }

    /// Direct layout selection — used by the segmented toolbar control and
    /// the `⌘⇧1/2/3` menu shortcuts. Skips the cycle path so a user going
    /// from `.vertical` to `.double` doesn't transit through `.single`,
    /// which would otherwise re-run `handleLayoutChange` twice and reset
    /// fit/zoom/scroll state along the way.
    func setLayout(_ target: PageLayout) {
        guard layout != target else { return }
        layout = target
    }

    func toggleDirection() {
        // Vertical strips have no left/right semantics — let the user keep
        // their preference for when they return to a paged layout.
        guard !layout.isContinuous else { return }
        direction = direction.isRTL ? .leftToRight : .rightToLeft
    }

    func toggleFitMode() {
        fitMode = fitMode.next
    }

    /// Direct fit-mode selection — used by the segmented toolbar control.
    /// The View menu's `⌘1/⌘2/⌘3` shortcuts assign `fitMode` directly so
    /// this isn't strictly required for keyboard, but routing through one
    /// method keeps callsites consistent and makes redundant assignments
    /// cheap (the didSet still fires only on actual changes).
    func setFitMode(_ target: FitMode) {
        guard fitMode != target else { return }
        fitMode = target
    }

    func toggleAutoFitOnResize() {
        autoFitOnResize.toggle()
    }

    func toggleSidebarPin() {
        sidebarMode.togglePin()
    }

    func revealSidebarOverlay() {
        sidebarMode.revealOverlay()
    }

    func dismissSidebarOverlay() {
        sidebarMode.dismissOverlay()
    }

    func toggleToolbarPin() {
        toolbarPinned.toggle()
    }

    func toggleThumbnailSidebar() {
        thumbnailSidebarVisible.toggle()
    }
}
