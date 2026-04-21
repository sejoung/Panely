# Performance Audit & TODO

Goal: keep Panely **fast and lightweight**. Audit conducted via codebase scan
of `Panely/Features/Reader`, `Panely/Features/Library`, `Panely/Core/Comic`.

Items grouped by impact. Check off as completed.

---

## 🔴 HIGH impact

### 1. `currentImages` + NSCache hold the same images twice
- **File**: `Panely/Features/Reader/ReaderViewModel.swift`
- **Problem**: In vertical mode, every page's `NSImage` lives in `currentImages` *and* `imageCache` (`countLimit = 10`). The cache eviction is never effective because `currentImages` keeps strong refs to all pages. A 100-page strip with 5 MB pages = ~500 MB locked until source changes.
- **Fix**: When the visible window moves, evict pages outside `[range ± buffer]` back to placeholder NSImages. Real images stay only in `imageCache` for fast restore on scroll-back.
- **Impact**: LARGE (50–80% memory reduction on big strips)
- **Risk**: LOW
- [x] Done — `evictPagesOutsideKeepWindow(visibleRange:)` runs sync at start of `setVisibleRange`. `lazyKeepBuffer = 10` pages each side. `loadPagesBatched` now takes a fresh `currentImages` snapshot just before write to avoid clobbering the eviction.

### 2. One `NSImageView` per page (no view recycling)
- **File**: `Panely/Features/Reader/ViewerContainer.swift` — `ImageStackView.layoutVertically`
- **Problem**: 1000-page strip = 1000 `NSImageView` instances. Only ~5–10 visible. Memory + per-scroll layout cost grows O(N).
- **Fix**: Reusable view pool (NSCollectionView-style recycler). Keep ~15 NSImageViews, swap their frames + images as the visible window changes.
- **Impact**: LARGE (>90% view-tree size reduction on big strips)
- **Risk**: MEDIUM (sizable refactor of ImageStackView; needs careful frame tracking)
- [ ] Done

### 3. Archive entry dimension read pulls the entire entry data
- **File**: `Panely/Core/Comic/ImageLoader.swift:18-30` + `ArchiveReader.loadData`
- **Problem**: `ImageLoader.dimensions(for:)` for `.archiveEntry` calls `reader.loadData(at: path)`, which forces ZIPFoundation to decompress the **whole image entry** just to read the header. 100-page CBZ = 500 MB+ disk + decompression at vertical entry.
- **Fix options**:
  - (a) Add partial-read API to `ArchiveReader` (first 64 KB usually has PNG/JPEG header).
  - (b) For non-nested archives, eagerly extract to a temp dir on vertical entry so subsequent dimension reads are file-URL header reads.
- **Impact**: LARGE (eliminates seconds of lag on archive vertical entry)
- **Risk**: MEDIUM (option a needs ZIPFoundation streaming; option b uses extra disk)
- [x] Done — option (a). `ArchiveReader.loadDataPrefix(at:maxBytes:)` uses ZIPFoundation's chunk consumer + `skipCRC32: true` and throws `ArchiveReaderError.prefixComplete` to bail at the requested byte count. `ImageLoader.dimensions` reads 64 KB prefix; falls back to full entry read only if `CGImageSource` can't extract dimensions from the prefix (rare — pathological EXIF blocks).

### 4. Unbounded `withTaskGroup` for dimension fetch
- **File**: `Panely/Features/Reader/ReaderViewModel.swift` — `refreshVerticalLazily`
- **Problem**: Spawns one concurrent task per page. 500-page folder = 500 tasks competing for the cooperative pool, opening file descriptors, holding buffers.
- **Fix**: Bound concurrency to ~`min(4, activeProcessorCount)` via a small async semaphore.
- **Impact**: MEDIUM (avoids spike, smoother launch)
- **Risk**: LOW
- [x] Done — chunked TaskGroup iteration in both `refreshVerticalLazily` (dimension fetch) and `loadPagesBatched` (decode), capped at `Self.lazyConcurrencyLimit` (`max(2, min(8, activeProcessorCount))`). Cancellation check between chunks too.

---

## 🟡 MEDIUM impact

### 5. `FileNode.loadTree` walks the whole tree to maxDepth=3
- **File**: `Panely/Features/Library/FileNode.swift:28-75`
- **Problem**: Every sidebar load runs full O(n²)-ish stat walk to depth 3, even if user never expands. 10,000-file library = 1–2 s I/O blocking sidebar.
- **Fix**: Load only immediate children up front. Mark expandable folders with `hasChildren: Bool?` and load deeper on user expand. Cache results.
- **Impact**: MEDIUM (large libraries open instantly)
- **Risk**: LOW
- [x] Done — pragmatic two-part fix instead of full lazy (SwiftUI `List(_:children:)` doesn't expose expand callbacks):
  1. **Two-phase reload in `LibrarySidebar.reload`** — load shallow tree (depth 1) and assign immediately, then load full tree (depth 3) in background and replace. User sees top-level folders/archives instantly.
  2. **Parallel top-level scan in `FileNode.loadTree`** — chunked TaskGroup processes top-level entries' subtrees concurrently (chunk size = `min(8, cores)`). Each subtree's recursion stays serial via `buildTreeSerial` to avoid `N^depth` task explosion.

### 6. `layoutSubtreeIfNeeded()` runs every `updateNSView`
- **File**: `Panely/Features/Reader/ViewerContainer.swift` — `updateNSView`
- **Problem**: Forces layout pass through entire view hierarchy on every prop change. With 1000 NSImageViews, this is the dominant cost during keyboard navigation (30+ Hz of forced layouts).
- **Fix**: Only call when `resetNeeded || pageChanged || layoutChanged`. Otherwise rely on AppKit's lazy layout.
- **Impact**: MEDIUM (50% layout CPU reduction during navigation)
- **Risk**: LOW (add guard, watch for visual regressions)
- [x] Done — guarded by `if resetNeeded`. Per-page navigation in paged mode and lazy-load image swaps in vertical mode skip the forced layout entirely.

### 7. `schedulePreload` loop missing `Task.isCancelled` check inside
- **File**: `Panely/Features/Reader/ReaderViewModel.swift` — `schedulePreload`
- **Problem**: Outer cancel works on prior task, but the loop body keeps decoding for pages the user already scrolled past.
- **Fix**: Add `if Task.isCancelled { return }` at top of each loop iteration.
- **Impact**: SMALL–MEDIUM (5–10% CPU during fast nav)
- **Risk**: LOW (one-line addition)
- [x] Done — added `Task.checkCancellation()` between data fetch and decode in `ImageLoader.load`, and post-load cancellation guard in `preloadIfNeeded` so cancelled work doesn't pollute the cache. The outer loop already had the per-iteration check.

### 8. `ReaderViewModel.init` reads `UserDefaults` 12× synchronously
- **File**: `Panely/Features/Reader/ReaderViewModel.swift` — init
- **Problem**: ~10–50 ms cold-start cost.
- **Fix**: Single `dictionaryRepresentation()` read or a Codable settings struct.
- **Impact**: SMALL (10–20 ms launch)
- **Risk**: LOW
- [x] Done — single `UserDefaults.standard.dictionaryRepresentation()` snapshot, then in-memory dict casts for every key.

---

## 🟢 LOW (micro-optimizations / polish)

### 9. `CenteringClipView.constrainBoundsRect` recomputes every scroll tick
- **File**: `Panely/Features/Reader/ViewerContainer.swift` — `CenteringClipView`
- **Fix**: Cache last `documentView.frame.size`, short-circuit when unchanged.
- **Impact**: SMALL (5–10% scroll latency)
- **Risk**: LOW
- [ ] Done

### 10. `HotEdgeReveal` `Task.sleep` doesn't check `isCancelled` post-sleep
- **File**: `Panely/Features/Reader/ReaderScene.swift` — `HotEdgeReveal`
- **Fix**: `guard !Task.isCancelled else { return }` after `await Task.sleep`.
- **Impact**: NEGLIGIBLE
- **Risk**: LOW
- [ ] Done

### 11. `RecentItemsStore.record` recreates bookmark even when item already exists
- **File**: `Panely/Features/Library/RecentItemsStore.swift:16-45`
- **Fix**: If path already in items, just reorder; skip `bookmarkData(...)`.
- **Impact**: SMALL (only repeat opens)
- **Risk**: LOW
- [ ] Done

### 12. `FitCalculator.magnification` not memoized
- **File**: `Panely/Features/Reader/FitCalculator.swift`
- **Fix**: Cache `(docSize, viewport, fitMode) -> CGFloat` on Coordinator (1-entry cache).
- **Impact**: SMALL
- **Risk**: LOW
- [ ] Done

### 13. `localizedStandardCompare` results not cached during sort
- **File**: `FileNode.swift`, `CBZLoader.swift`, `FolderLoader.swift`
- **Fix**: Skip unless profiling shows a hotspot — sorts happen once per load.
- **Impact**: NEGLIGIBLE
- **Risk**: N/A
- [ ] Done

---

## Suggested phasing

**Phase 1** — quick wins, low risk: #1, #4, #6, #7, #8
**Phase 2** — medium effort: #5, #3
**Phase 3** — biggest refactor: #2
**Polish** — anytime: #9, #10, #11, #12

---

## Methodology
- Read every Swift file in `Panely/`
- Traced concurrent task spawn patterns + memory retention
- Mapped data flow load → cache → view hierarchy
- Measured assumed costs against typical scenarios (100/500/1000-page sources)

Confidence: HIGH on findings. Each fix is scoped with concrete file/line +
risk + impact estimate.
