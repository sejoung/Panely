import AppKit
import Foundation

@MainActor
final class ReaderImageMemoryCache {
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 100
        cache.totalCostLimit = ReaderImageMemoryCache.costLimit()
        return cache
    }()

    static let minCostLimit: UInt64 = 150 * 1024 * 1024
    static let maxCostLimit: UInt64 = 1024 * 1024 * 1024

    /// Image-memory budget scaled to the host's RAM. A fixed cap thrashed on
    /// high-res scan series (a single 2000×3000 page ≈ 24 MB, so a 150 MB cap
    /// held only ~6 pages — tighter than preload + spread want), while a
    /// large fixed cap would over-commit on small machines. ~1/16 of physical
    /// memory, clamped to [150 MB, 1 GB].
    static func costLimit() -> Int {
        costLimit(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    /// Pure clamp policy, split out so the boundaries are unit-testable
    /// without depending on the host's actual RAM.
    static func costLimit(physicalMemory: UInt64) -> Int {
        let target = physicalMemory / 16
        let clamped = min(max(target, minCostLimit), maxCostLimit)
        return Int(clamped)
    }

    func image(for page: ComicPage) -> NSImage? {
        cache.object(forKey: page.id as NSString)
    }

    func store(_ image: NSImage, for page: ComicPage) {
        cache.setObject(image, forKey: page.id as NSString, cost: Self.estimatedBitmapCost(of: image))
    }

    static func estimatedBitmapCost(of image: NSImage) -> Int {
        if let rep = image.representations.first {
            let w = rep.pixelsWide
            let h = rep.pixelsHigh
            if w > 0 && h > 0 {
                let bitsPerSample = (rep as? NSBitmapImageRep)?.bitsPerSample ?? 8
                let samplesPerPixel = (rep as? NSBitmapImageRep)?.samplesPerPixel ?? 4
                let bytesPerPixel = max(1, (bitsPerSample * samplesPerPixel) / 8)
                return w * h * bytesPerPixel
            }
        }
        return Int(image.size.width * image.size.height * 4)
    }
}

/// One decode per page, however many callers want it. A page already decoding
/// for preload (or for a lazy batch the user just scrolled past) is joined
/// rather than decoded a second time — ImageIO can't be interrupted, so
/// starting over costs a full decode on top of the one still running.
///
/// The decode runs in its own task so that it outlives any one caller, and is
/// cancelled only when every caller has gone.
@MainActor
final class ReaderInFlightDecodes {
    fileprivate final class Entry {
        let token: Int
        let task: Task<NSImage, Error>
        var waiters = 0

        init(token: Int, task: Task<NSImage, Error>) {
            self.token = token
            self.task = task
        }
    }

    private var entries: [String: Entry] = [:]
    private var nextToken = 0

    var activeCount: Int { entries.count }

    func image(
        forID id: String,
        decode: @escaping @MainActor () async throws -> NSImage
    ) async throws -> NSImage {
        let entry = entries[id] ?? start(id: id, decode: decode)
        entry.waiters += 1
        return try await withTaskCancellationHandler {
            try await entry.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.release(entry, id: id)
            }
        }
    }

    private func start(
        id: String,
        decode: @escaping @MainActor () async throws -> NSImage
    ) -> Entry {
        nextToken &+= 1
        let token = nextToken
        // Runs on the main actor, so it can't reach `defer` before `entries`
        // has been filled in below.
        let task = Task { @MainActor [weak self] in
            defer {
                if let self, self.entries[id]?.token == token {
                    self.entries[id] = nil
                }
            }
            return try await decode()
        }
        let entry = Entry(token: token, task: task)
        entries[id] = entry
        return entry
    }

    /// Keeps whichever of these pages are decoding alive until `release`.
    ///
    /// A replacement batch needs this: cancelling the old batch and starting
    /// the new one both go through the main actor, and the cancellation gets
    /// there first — so without a hold, a page both batches want would lose its
    /// last caller and be cancelled just before the new batch asked for it.
    struct Hold {
        fileprivate let entries: [(id: String, entry: Entry)]
    }

    func hold(ids: [String]) -> Hold {
        Hold(entries: ids.compactMap { id in
            guard let entry = entries[id] else { return nil }
            entry.waiters += 1
            return (id, entry)
        })
    }

    func release(_ hold: Hold) {
        for (id, entry) in hold.entries {
            release(entry, id: id)
        }
    }

    /// A caller was cancelled. Only the last one out stops the decode, and it
    /// also forgets the entry so a later request starts afresh instead of
    /// joining a task that is about to throw `CancellationError`.
    private func release(_ entry: Entry, id: String) {
        entry.waiters -= 1
        guard entry.waiters <= 0 else { return }
        entry.task.cancel()
        if entries[id]?.token == entry.token {
            entries[id] = nil
        }
    }
}

nonisolated enum ReaderImageLoadingPolicy {
    static let preloadRadius = 2
    static let lazyWindowRadius = 3
    static let lazyKeepBuffer = 10
    static let visibleRangeBuffer = 2

    static var lazyConcurrencyLimit: Int {
        max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
    }
}

nonisolated struct ReaderVerticalImageWindow {
    let pageCount: Int

    /// `indices` ordered for decoding: on-screen pages first, then outward.
    /// Batches decode in chunks, so ascending order would make the viewer wait
    /// for the off-screen pages above it before showing what's in view.
    static func visibleFirst(_ indices: [Int], visibleRange range: Range<Int>) -> [Int] {
        func distance(_ i: Int) -> Int {
            if i < range.lowerBound { return range.lowerBound - i }
            return i < range.upperBound ? 0 : i - (range.upperBound - 1)
        }
        return indices.sorted { (distance($0), $0) < (distance($1), $1) }
    }

    func initialIndices(around index: Int, excluding loaded: Set<Int>) -> [Int] {
        guard pageCount > 0 else { return [] }
        let lower = max(0, index - ReaderImageLoadingPolicy.lazyWindowRadius)
        let upper = min(pageCount - 1, index + ReaderImageLoadingPolicy.lazyWindowRadius)
        guard lower <= upper else { return [] }
        return (lower...upper).filter { !loaded.contains($0) }
    }

    func loadIndices(forVisibleRange range: Range<Int>, excluding loaded: Set<Int>) -> [Int] {
        guard !range.isEmpty else { return [] }
        let lower = max(0, range.lowerBound - ReaderImageLoadingPolicy.visibleRangeBuffer)
        let upper = min(pageCount, range.upperBound + ReaderImageLoadingPolicy.visibleRangeBuffer)
        guard lower < upper else { return [] }
        return (lower..<upper).filter { !loaded.contains($0) }
    }

    func keepRange(forVisibleRange range: Range<Int>, loadedImageCount: Int) -> Range<Int> {
        let lower = max(0, range.lowerBound - ReaderImageLoadingPolicy.lazyKeepBuffer)
        let upper = min(loadedImageCount, range.upperBound + ReaderImageLoadingPolicy.lazyKeepBuffer)
        return lower..<max(lower, upper)
    }

    /// Loaded pages to drop back to placeholders for `range`: every page
    /// outside `keepRange`, plus — when the pages left inside it still cost
    /// more than `byteBudget` — the ones farthest from the viewport until the
    /// rest fits. A count-only window held visible + 20 full-res bitmaps
    /// whatever their size; on tall webtoon slices that is gigabytes.
    ///
    /// Pages within `visibleRangeBuffer` of `range` are never evicted, even
    /// over budget: they're exactly what `loadIndices` re-requests, so
    /// evicting them would decode them again on the next scroll tick.
    func evictionIndices(
        forVisibleRange range: Range<Int>,
        loaded: Set<Int>,
        loadedImageCount: Int,
        byteBudget: Int,
        cost: (Int) -> Int
    ) -> [Int] {
        guard !range.isEmpty else { return [] }
        let keep = keepRange(forVisibleRange: range, loadedImageCount: loadedImageCount)
        var evicted = loaded.filter { !keep.contains($0) }
        let kept = loaded.subtracting(evicted)

        var total = kept.reduce(0) { $0 + cost($1) }
        if total > byteBudget {
            let buffer = ReaderImageLoadingPolicy.visibleRangeBuffer
            let protected = (range.lowerBound - buffer)..<(range.upperBound + buffer)
            func distance(_ i: Int) -> Int {
                i < range.lowerBound ? range.lowerBound - i : i - (range.upperBound - 1)
            }
            let candidates = kept
                .filter { !protected.contains($0) }
                .sorted { (distance($0), $0) > (distance($1), $1) }
            for i in candidates where total > byteBudget {
                evicted.insert(i)
                total -= cost(i)
            }
        }
        return evicted.sorted()
    }
}

nonisolated enum ReaderImagePlaceholder {
    static func make(size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.13, alpha: 1).setFill()
            rect.fill()
            return true
        }
    }

    static func makeError(size: CGSize, title: String) -> NSImage {
        let safeSize = CGSize(width: max(size.width, 320), height: max(size.height, 240))
        return NSImage(size: safeSize, flipped: false) { rect in
            NSColor(white: 0.10, alpha: 1).setFill()
            rect.fill()

            let border = NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2))
            NSColor.systemRed.withAlphaComponent(0.65).setStroke()
            border.lineWidth = 4
            border.stroke()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: min(42, max(18, safeSize.width / 18)), weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
                .paragraphStyle: paragraph,
            ]
            let text = String(localized: "Failed to load\n\(title)", bundle: .localized)
            let textRect = rect.insetBy(dx: 32, dy: max(32, rect.height * 0.35))
            text.draw(in: textRect, withAttributes: attributes)
            return true
        }
    }
}
