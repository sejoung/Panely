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
        let range = currentSpread
        guard !range.isEmpty, source.pages.indices.contains(range.lowerBound) else { return [] }
        return Array(source.pages[range])
    }

    /// Page-index range of the spread currently on screen. The single source
    /// of truth for the visible span in paged layouts (see `SpreadCalculator`).
    var currentSpread: Range<Int> {
        SpreadCalculator.spread(
            containing: currentPageIndex,
            pageCount: source.pageCount,
            step: navigationStep,
            coverAlone: spreadCoverAlone
        )
    }

    var pageCounterLabel: String {
        guard !source.isEmpty else { return "" }
        let count = totalPages
        let range = currentSpread
        let first = range.lowerBound + 1
        let last = range.upperBound
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
        return currentSpread.upperBound
    }

    // MARK: - Page navigation

    func next() {
        guard let target = SpreadCalculator.nextStart(
            from: currentPageIndex,
            pageCount: source.pageCount,
            step: navigationStep,
            coverAlone: spreadCoverAlone
        ) else { return }
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

        let willLandOnZero = (SpreadCalculator.previousStart(
            from: currentPageIndex,
            pageCount: source.pageCount,
            step: navigationStep,
            coverAlone: spreadCoverAlone
        ) ?? 0) == 0
        previous()
        // `previous()` triggers the didSet that resets the cue. If we just
        // landed on page 0 with a prev sibling, re-arm so the user's next
        // press advances volumes without a wasted no-op press first.
        if willLandOnZero && canGoPreviousVolume {
            wantsPreviousVolumePrompt = true
        }
    }

    func previous() {
        guard let target = SpreadCalculator.previousStart(
            from: currentPageIndex,
            pageCount: source.pageCount,
            step: navigationStep,
            coverAlone: spreadCoverAlone
        ) else {
            // Already in the first spread; snap to 0 only if we somehow sit
            // mid-spread (e.g., a stale index from a layout switch).
            guard currentPageIndex > 0 else { return }
            currentPageIndex = 0
            scheduleRefreshIfPaged()
            return
        }
        currentPageIndex = target
        scheduleRefreshIfPaged()
    }

    func jump(to index: Int) {
        guard source.pageCount > 0 else { return }
        let snapped = SpreadCalculator.spread(
            containing: index,
            pageCount: source.pageCount,
            step: navigationStep,
            coverAlone: spreadCoverAlone
        ).lowerBound
        guard snapped != currentPageIndex else { return }
        currentPageIndex = snapped
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
        // explicit fit choice is preserved. The viewer still reapplies that
        // fit against the new layout geometry so vertical zoom does not leak
        // into single/double page viewing.
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

    /// Flip the standalone-cover spread offset. Re-aligns the current page to
    /// the new spread boundary and re-decodes so the pairing changes on screen
    /// immediately. A no-op visually outside double-page mode (the preference
    /// still persists for when the user returns to double).
    func toggleDoublePageCoverAlone() {
        doublePageCoverAlone.toggle()
        guard layout == .double else { return }
        let aligned = SpreadCalculator.spread(
            containing: currentPageIndex,
            pageCount: source.pageCount,
            step: navigationStep,
            coverAlone: spreadCoverAlone
        ).lowerBound
        if aligned != currentPageIndex {
            currentPageIndex = aligned
        }
        // Refresh even when the index is unchanged — the pairing (and thus the
        // visible spread) still differs under the new offset.
        scheduleRefreshIfPaged()
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
