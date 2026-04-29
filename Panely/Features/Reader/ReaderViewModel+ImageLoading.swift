import AppKit
import Foundation

/// Image decoding, paged preload, vertical lazy windowing with eviction, and
/// the shared `refreshImages` router that picks between paged / vertical
/// refresh. Layout-change orchestration (`handleLayoutChange`) lives here
/// because its side effects are image-loading concerns.
extension ReaderViewModel {

    // MARK: - Layout change orchestration

    func handleLayoutChange(from oldLayout: PageLayout) {
        // Skip when init is restoring from UserDefaults — there's no source
        // to refresh and we don't want a phantom isLoading=true.
        guard isFullyInitialized else { return }

        UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey)
        let step = navigationStep
        currentPageIndex = (currentPageIndex / step) * step

        // Going from paged to vertical: clear stale paged images and show
        // a loading indicator immediately. Without this the user sees the
        // viewer's empty state for the duration of the dimension fetch +
        // initial window load (which can be a noticeable beat for big
        // folders). refreshVerticalLazily / refreshImages clear isLoading
        // when they finish.
        if layout.isContinuous && !oldLayout.isContinuous {
            currentImages = []
            isLoading = true
            loadingMessage = "Building vertical strip…"
        }
        Task { await refreshImages() }
    }

    // MARK: - Refresh routing

    func refreshImages() async {
        // Cancel any in-flight lazy-load from a previous source/layout.
        lazyLoadTask?.cancel()
        lazyLoadTask = nil
        loadedPageIndices.removeAll()

        // Capture the load epoch so a refresh that finishes after a newer
        // load() has started doesn't clear the loading indicator on the
        // newer load's behalf. Layout-toggle refreshes don't bump the epoch,
        // so they'll clear normally.
        let epochAtStart = loadEpoch

        if layout.isContinuous {
            await refreshVerticalLazily()
        } else {
            await refreshPaged()
        }

        // Always clear the loading flag when refresh completes — covers the
        // toggleLayout-driven path where handleLayoutChange set it to true.
        // load() also clears via its own defer; double-clear is harmless.
        if epochAtStart == loadEpoch {
            isLoading = false
            loadingMessage = ""
        }
    }

    private func refreshPaged() async {
        let pages = visiblePages
        pageDimensions = []
        guard !pages.isEmpty else {
            currentImages = []
            return
        }

        var images: [NSImage] = []
        for page in pages {
            if let image = await loadVisibleImage(page) {
                images.append(image)
            }
        }
        currentImages = images

        schedulePreload()
    }

    /// Vertical mode: fetch all page dimensions concurrently (header-only,
    /// fast), populate the strip with same-sized placeholder NSImages so the
    /// layout is correct from frame 1, then load real images for the window
    /// around `currentPageIndex`. Subsequent loads are triggered by
    /// `setCurrentPageFromScroll` as the user scrolls.
    private func refreshVerticalLazily() async {
        let pages = source.pages
        guard !pages.isEmpty else {
            currentImages = []
            pageDimensions = []
            return
        }

        // 1. Fetch dimensions in bounded-concurrency chunks. Spawning one
        //    task per page on big folders (500+) blew through the cooperative
        //    pool and held a buffer per task; chunking caps concurrency at
        //    ~core count without losing throughput. Falls back to a generic
        //    portrait aspect for any page whose header read fails so layout
        //    still holds.
        let fallbackSize = CGSize(width: 1000, height: 1500)
        let maxConcurrent = Self.lazyConcurrencyLimit
        var dims = Array(repeating: fallbackSize, count: pages.count)
        for chunkStart in stride(from: 0, to: pages.count, by: maxConcurrent) {
            let chunkEnd = min(chunkStart + maxConcurrent, pages.count)
            await withTaskGroup(of: (Int, CGSize).self) { group in
                for i in chunkStart..<chunkEnd {
                    let page = pages[i]
                    group.addTask {
                        let size = (try? await ImageLoader.dimensions(for: page)) ?? fallbackSize
                        return (i, size)
                    }
                }
                for await (i, size) in group {
                    dims[i] = size
                }
            }
        }
        pageDimensions = dims

        // 2. Placeholders give ImageStackView the right frame for every slot.
        //    Use a visible neutral gray so unloaded slots look intentional
        //    instead of empty black voids during the brief load window.
        currentImages = dims.map { Self.makePlaceholder(size: $0) }

        // 3. Load the window around the restored page index.
        await ensureWindowLoaded(around: currentPageIndex)
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
        guard layout.isContinuous else { return }
        guard !range.isEmpty else { return }

        // Free pages outside the keep window first — runs sync so memory
        // is released even if the load below gets cancelled by another
        // setVisibleRange before completing.
        evictPagesOutsideKeepWindow(visibleRange: range)

        let buffer = 2
        let lower = max(0, range.lowerBound - buffer)
        let upper = min(source.pageCount, range.upperBound + buffer)
        let needed = (lower..<upper).filter { !loadedPageIndices.contains($0) }
        guard !needed.isEmpty else { return }

        lazyLoadTask?.cancel()
        lazyLoadTask = Task { [weak self] in
            await self?.loadPagesBatched(needed)
        }
    }

    /// Replace pages outside `[range ± lazyKeepBuffer]` with placeholder
    /// NSImages so their decoded bitmaps can be released. NSCache still
    /// holds the recently-decoded images, so scrolling back within a few
    /// pages typically hits the cache and re-displays instantly.
    private func evictPagesOutsideKeepWindow(visibleRange: Range<Int>) {
        guard !pageDimensions.isEmpty, !loadedPageIndices.isEmpty else { return }
        let lower = max(0, visibleRange.lowerBound - lazyKeepBuffer)
        let upper = min(currentImages.count, visibleRange.upperBound + lazyKeepBuffer)

        var newImages = currentImages
        var evicted: [Int] = []
        for i in loadedPageIndices where i < lower || i >= upper {
            guard i < newImages.count, i < pageDimensions.count else { continue }
            newImages[i] = Self.makePlaceholder(size: pageDimensions[i])
            evicted.append(i)
        }
        guard !evicted.isEmpty else { return }
        for i in evicted { loadedPageIndices.remove(i) }
        currentImages = newImages
    }

    /// Load `indices` concurrently and apply ALL results in a single
    /// `currentImages` assignment. Single SwiftUI render = single
    /// updateNSView = single setImages incremental swap, regardless of how
    /// many pages were just loaded. Critical when zoom-out triggers many
    /// pages to load at once — without batching, each completion fires its
    /// own re-render and the main thread saturates.
    private func loadPagesBatched(_ indices: [Int]) async {
        guard !indices.isEmpty else { return }
        var loaded: [(Int, NSImage)] = []
        let maxConcurrent = Self.lazyConcurrencyLimit

        // Decode in bounded chunks. Decoding is CPU-heavy so spawning every
        // page at once would saturate the pool with no real benefit (cores
        // are bounded anyway) while still costing per-task overhead.
        for chunkStart in stride(from: 0, to: indices.count, by: maxConcurrent) {
            if Task.isCancelled { return }
            let chunkEnd = min(chunkStart + maxConcurrent, indices.count)
            await withTaskGroup(of: (Int, NSImage?).self) { group in
                for i in chunkStart..<chunkEnd {
                    let pageIndex = indices[i]
                    guard !loadedPageIndices.contains(pageIndex),
                          source.pages.indices.contains(pageIndex) else { continue }
                    let page = source.pages[pageIndex]
                    group.addTask {
                        let image = await self.loadVisibleImage(page)
                        return (pageIndex, image)
                    }
                }
                for await (pageIndex, image) in group {
                    if Task.isCancelled { return }
                    if let image {
                        loaded.append((pageIndex, image))
                        loadedPageIndices.insert(pageIndex)
                    }
                }
            }
        }

        guard !Task.isCancelled, !loaded.isEmpty else { return }
        // Take a fresh snapshot — concurrent evictions or other lazy loads
        // may have mutated currentImages during the awaits above. Merge our
        // new pages into the latest state and write once.
        var newImages = currentImages
        for (i, image) in loaded where i < newImages.count {
            newImages[i] = image
        }
        currentImages = newImages
    }

    /// Load real images for pages in `[index - radius ... index + radius]`
    /// that aren't already loaded. Concurrent with bounded fan-out.
    /// Updates `currentImages` once at the end so SwiftUI re-renders the
    /// strip a single time instead of per loaded image.
    private func ensureWindowLoaded(around index: Int) async {
        let lower = max(0, index - lazyWindowRadius)
        let upper = min(source.pageCount - 1, index + lazyWindowRadius)
        guard lower <= upper else { return }
        let needed = (lower...upper).filter { !loadedPageIndices.contains($0) }
        guard !needed.isEmpty else { return }

        await loadPagesBatched(needed)
    }

    // MARK: - Paged preload

    private func cachedImage(for page: ComicPage) -> NSImage? {
        imageCache.object(forKey: page.id.uuidString as NSString)
    }

    private func cacheImage(_ image: NSImage, for page: ComicPage) {
        imageCache.setObject(image, forKey: page.id.uuidString as NSString)
    }

    func loadVisibleImage(_ page: ComicPage) async -> NSImage? {
        if let cached = cachedImage(for: page) {
            return cached
        }
        do {
            let image = try await ImageLoader.load(page)
            cacheImage(image, for: page)
            return image
        } catch {
            errorMessage = "Failed to load \(page.displayName)"
            return nil
        }
    }

    private func preloadIfNeeded(_ page: ComicPage) async {
        if cachedImage(for: page) != nil { return }
        if Task.isCancelled { return }
        guard let image = try? await ImageLoader.load(page) else { return }
        // Don't pollute the cache with work the caller no longer wants —
        // important for rapid keyboard navigation where pages stream past
        // faster than decode completes.
        if Task.isCancelled { return }
        cacheImage(image, for: page)
    }

    private func pagesToPreload() -> [ComicPage] {
        guard !source.pages.isEmpty else { return [] }
        let step = navigationStep
        let visibleEnd = min(currentPageIndex + step, source.pageCount)
        let start = max(0, currentPageIndex - preloadRadius * step)
        let end = min(source.pageCount, visibleEnd + preloadRadius * step)

        var result: [ComicPage] = []
        let visibleRange = currentPageIndex..<visibleEnd
        for i in start..<end where !visibleRange.contains(i) {
            result.append(source.pages[i])
        }
        return result
    }

    private func schedulePreload() {
        preloadTask?.cancel()
        let pages = pagesToPreload()
        guard !pages.isEmpty else { return }

        preloadTask = Task { [weak self] in
            for page in pages {
                if Task.isCancelled { return }
                await self?.preloadIfNeeded(page)
            }
        }
    }

    // MARK: - Placeholders + concurrency limit

    static func makePlaceholder(size: CGSize) -> NSImage {
        // drawingHandler is invoked lazily by AppKit when the image is actually
        // drawn, so this stays cheap (no upfront pixel allocation).
        NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.13, alpha: 1).setFill()
            rect.fill()
            return true
        }
    }

    /// Concurrency cap for header-fetch / decode TaskGroups. ~Core count
    /// keeps the pool busy without overcommitting; clamped to [2, 8] so
    /// neither single-core hosts nor monster CPUs spin up pathological
    /// numbers of tasks.
    static var lazyConcurrencyLimit: Int {
        max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
    }
}
