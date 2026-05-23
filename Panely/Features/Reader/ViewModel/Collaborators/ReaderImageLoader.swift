import AppKit
import Foundation

/// Owns everything the viewer needs to render images: the decoded image array
/// for the active layout, the per-page dimension table that drives vertical
/// strip placeholders, the bounded NSCache, and the lazy-window/preload
/// orchestration. State that depends on the open book lives here so that
/// `ReaderViewModel` doesn't have to mix cache-budget tuning constants in
/// with navigation/source state.
///
/// All decisions take a snapshot of `ComicSource` / `PageLayout` / page index
/// as parameters — the loader has no opinion about which book or where the
/// user is, the caller (ReaderViewModel) supplies that context per call.
/// Errors flow back through an `onError` closure rather than mutating a
/// shared `errorMessage`, keeping the loader free of view-model coupling.
@Observable
@MainActor
final class ReaderImageLoader {
    // MARK: - View-observed state

    var currentImages: [NSImage] = []

    /// Vertical-mode dimension table. Populated up-front (cheap header reads);
    /// `currentImages` starts as same-sized placeholder `NSImage(size:)`
    /// instances and is replaced one-by-one as real images decode inside the
    /// visible window. `loadedPageIndices` tracks which slots already hold
    /// real (non-placeholder) images.
    var pageDimensions: [CGSize] = []

    private(set) var loadedPageIndices: Set<Int> = []

    // MARK: - Cache + async state

    let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // countLimit is intentionally loose — the real budget is `totalCostLimit`.
        // Vertical lazy windows (`lazyWindowRadius` + `lazyKeepBuffer`) can pin
        // ~25 pages around the visible band; setting the count cap close to that
        // caused premature eviction of small pages even when far under the byte
        // budget, hurting prefetch hit-rate on flips. Cost-driven eviction does
        // the right thing for both huge and small pages.
        cache.countLimit = 100
        // High-res scans (10000×14000 ≈ 600 MB decoded) could otherwise stack
        // up to many GB of RSS. The byte cap means typical smaller pages stay
        // cached generously, while a few huge pages get evicted before they
        // pin too much memory. Per-entry cost is fed in by `cacheImage(_:for:)`
        // based on pixel area × 4.
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()

    private var preloadTask: Task<Void, Never>?
    private var lazyLoadTask: Task<Void, Never>?

    // Snapshot of the most recent refresh() inputs. Preload reads from these
    // since it runs after refresh() returns; cancellation on the next refresh
    // takes care of stale snapshots.
    private var lastSource: ComicSource = .empty
    private var lastLayout: PageLayout = .single
    private var lastPageIndex: Int = 0
    private var lastNavigationStep: Int = 1

    // MARK: - Tuning

    private let preloadRadius = 2
    private let lazyWindowRadius = 3
    /// Pages outside `[visibleRange ± lazyKeepBuffer]` get evicted back to
    /// placeholders so a long strip doesn't pin every loaded image in memory.
    /// Wider than the load buffer so small back-scrolls don't immediately
    /// re-decode. NSCache still holds recents for fast restore.
    private let lazyKeepBuffer = 10

    // MARK: - Lifecycle

    /// Clear all per-book state. Used when a load fails and the source is
    /// being wiped.
    func reset() {
        preloadTask?.cancel()
        preloadTask = nil
        lazyLoadTask?.cancel()
        lazyLoadTask = nil
        currentImages = []
        pageDimensions = []
        loadedPageIndices.removeAll()
    }

    /// Clear the strip in preparation for a paged→vertical rebuild. The
    /// caller is responsible for calling `refresh(...)` immediately after to
    /// repopulate.
    func prepareForVerticalRebuild() {
        currentImages = []
    }

    /// Cancel any pending preload — called when a new `load(url:)` begins so
    /// background decodes for the previous book don't waste CPU.
    func cancelPreload() {
        preloadTask?.cancel()
    }

    // MARK: - Refresh entry point

    func refresh(
        source: ComicSource,
        layout: PageLayout,
        currentPageIndex: Int,
        navigationStep: Int,
        isCancelled: @MainActor @escaping () -> Bool,
        onError: @MainActor @escaping (String) -> Void
    ) async {
        // Cancel any in-flight lazy-load from a previous source/layout.
        lazyLoadTask?.cancel()
        lazyLoadTask = nil
        loadedPageIndices.removeAll()

        lastSource = source
        lastLayout = layout
        lastPageIndex = currentPageIndex
        lastNavigationStep = navigationStep

        if layout.isContinuous {
            await refreshVerticalLazily(source: source, currentPageIndex: currentPageIndex, isCancelled: isCancelled, onError: onError)
        } else {
            await refreshPaged(source: source, currentPageIndex: currentPageIndex, navigationStep: navigationStep, onError: onError)
        }
    }

    private func refreshPaged(
        source: ComicSource,
        currentPageIndex: Int,
        navigationStep: Int,
        onError: @MainActor @escaping (String) -> Void
    ) async {
        let pages = visiblePages(source: source, currentPageIndex: currentPageIndex, navigationStep: navigationStep)
        pageDimensions = []
        guard !pages.isEmpty else {
            currentImages = []
            return
        }

        // Parallel decode. In single-page layout this is a no-op (one task);
        // in double-page mode the two pages decode concurrently instead of
        // back-to-back, which is roughly a 2× speedup on the spread refresh.
        // Index-tagged + sorted so spread order is preserved regardless of
        // which decode finishes first.
        let images = await withTaskGroup(of: (Int, NSImage?).self, returning: [NSImage].self) { group in
            for (i, page) in pages.enumerated() {
                group.addTask { [self] in
                    let image = await self.loadVisibleImage(page, onError: onError)
                    return (i, image)
                }
            }
            var slots: [(Int, NSImage?)] = []
            for await result in group {
                slots.append(result)
            }
            slots.sort { $0.0 < $1.0 }
            return slots.compactMap { $0.1 }
        }
        currentImages = images

        schedulePreload()
    }

    /// Vertical mode: fetch all page dimensions concurrently (header-only,
    /// fast), populate the strip with same-sized placeholder NSImages so the
    /// layout is correct from frame 1, then load real images for the window
    /// around `currentPageIndex`. Subsequent loads are triggered by
    /// `setVisibleRange(_:)` as the user scrolls.
    private func refreshVerticalLazily(
        source: ComicSource,
        currentPageIndex: Int,
        isCancelled: @MainActor @escaping () -> Bool,
        onError: @MainActor @escaping (String) -> Void
    ) async {
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
            if isCancelled() { return }
        }
        pageDimensions = dims

        // 2. Placeholders give ImageStackView the right frame for every slot.
        //    Use a visible neutral gray so unloaded slots look intentional
        //    instead of empty black voids during the brief load window.
        currentImages = dims.map { Self.makePlaceholder(size: $0) }

        // 3. Load the window around the restored page index.
        await ensureWindowLoaded(around: currentPageIndex, source: source, onError: onError)
    }

    // MARK: - Visible-range driven updates

    /// Load every page in `range ± buffer` that isn't already a real image,
    /// and evict any loaded pages that have scrolled outside the keep window.
    /// Caller is expected to gate on `layout.isContinuous` before calling.
    func setVisibleRange(
        _ range: Range<Int>,
        source: ComicSource,
        layout: PageLayout,
        onError: @MainActor @escaping (String) -> Void
    ) {
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
            await self?.loadPagesBatched(needed, source: source, onError: onError)
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
    private func loadPagesBatched(
        _ indices: [Int],
        source: ComicSource,
        onError: @MainActor @escaping (String) -> Void
    ) async {
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
                        let image = await self.loadVisibleImage(page, onError: onError)
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
    private func ensureWindowLoaded(
        around index: Int,
        source: ComicSource,
        onError: @MainActor @escaping (String) -> Void
    ) async {
        let lower = max(0, index - lazyWindowRadius)
        let upper = min(source.pageCount - 1, index + lazyWindowRadius)
        guard lower <= upper else { return }
        let needed = (lower...upper).filter { !loadedPageIndices.contains($0) }
        guard !needed.isEmpty else { return }

        await loadPagesBatched(needed, source: source, onError: onError)
    }

    // MARK: - Cache helpers

    private func cachedImage(for page: ComicPage) -> NSImage? {
        imageCache.object(forKey: page.id as NSString)
    }

    private func cacheImage(_ image: NSImage, for page: ComicPage) {
        // Decoded byte estimate. Prefer the actual bitmap rep's pixel
        // dimensions when available — `image.size` is in points, so Retina
        // (2×) backing or 16-bit/HDR scans were systematically under-priced
        // by the simple "points × 4" formula. Falls back to the point-based
        // estimate when no rep advertises pixel dimensions.
        let cost = Self.estimatedBitmapCost(of: image)
        imageCache.setObject(image, forKey: page.id as NSString, cost: cost)
    }

    static func estimatedBitmapCost(of image: NSImage) -> Int {
        if let rep = image.representations.first {
            // pixelsWide/High return 0 for non-bitmap reps; guard against
            // that by falling through to the size-based estimate.
            let w = rep.pixelsWide
            let h = rep.pixelsHigh
            if w > 0 && h > 0 {
                // bitsPerSample × samplesPerPixel ÷ 8 is the per-pixel byte
                // cost; defaults of 8/4 cover the common 32-bit RGBA case
                // and conservatively over-estimate sub-8-bit reps.
                let bitsPerSample = (rep as? NSBitmapImageRep)?.bitsPerSample ?? 8
                let samplesPerPixel = (rep as? NSBitmapImageRep)?.samplesPerPixel ?? 4
                let bytesPerPixel = max(1, (bitsPerSample * samplesPerPixel) / 8)
                return w * h * bytesPerPixel
            }
        }
        return Int(image.size.width * image.size.height * 4)
    }

    private func loadVisibleImage(_ page: ComicPage, onError: @MainActor @escaping (String) -> Void) async -> NSImage? {
        if let cached = cachedImage(for: page) {
            return cached
        }
        do {
            let image = try await ImageLoader.load(page)
            cacheImage(image, for: page)
            return image
        } catch {
            onError("Failed to load \(page.displayName)")
            return nil
        }
    }

    // MARK: - Paged preload

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
        guard !lastSource.pages.isEmpty else { return [] }
        let step = lastNavigationStep
        let visibleEnd = min(lastPageIndex + step, lastSource.pageCount)
        let start = max(0, lastPageIndex - preloadRadius * step)
        let end = min(lastSource.pageCount, visibleEnd + preloadRadius * step)

        var result: [ComicPage] = []
        let visibleRange = lastPageIndex..<visibleEnd
        for i in start..<end where !visibleRange.contains(i) {
            result.append(lastSource.pages[i])
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

    // MARK: - Visible-page span (for paged refresh)

    private func visiblePages(source: ComicSource, currentPageIndex: Int, navigationStep: Int) -> [ComicPage] {
        let start = currentPageIndex
        guard source.pages.indices.contains(start) else { return [] }
        let end = min(start + navigationStep, source.pageCount)
        return Array(source.pages[start..<end])
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
