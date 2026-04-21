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

    func toggleDirection() {
        // Vertical strips have no left/right semantics — let the user keep
        // their preference for when they return to a paged layout.
        guard !layout.isContinuous else { return }
        direction = direction.isRTL ? .leftToRight : .rightToLeft
    }

    func toggleFitMode() {
        fitMode = fitMode.next
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
