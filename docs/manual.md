<p align="right">
  <strong>English</strong> · <a href="manual.ko.md">한국어</a>
</p>

# Panely — User Manual

A visual walkthrough of Panely's reader interface. For the full feature
list, shortcuts table, and build instructions, see the
[README](../README.md).

---

## At a glance

The reader keeps a layout-agnostic chrome that gets out of your way:

![Reading a single page with library pinned](screenshots/01-hero-single-page.png)

- **Library sidebar** (left, pinnable) — folder tree, favorites, and per-book bookmarks.
- **Floating toolbar** (top, auto-hides) — layout / fit / zoom / favorite / bookmark / navigation.
- **Viewer** — the page itself, auto-centered with pinch + scroll-wheel zoom.
- **Page slider** (bottom, auto-hides) — quick-jump field plus volume + page counter.

---

## Opening a book

On first launch the library is empty:

![Empty sidebar prompting folder selection](screenshots/06-sidebar-empty.png)

Choose **Pick Folder…** (or press `⌘O`, or drag a folder onto the app
icon) to grant access. Once granted, the sidebar populates with your tree
and any per-book state:

![Populated sidebar with favorites and bookmarks](screenshots/05-sidebar-populated.png)

The sidebar surfaces up to three sections automatically:

- **Favorites** — books you've starred (`⌘⇧D` or the ★ toolbar button).
- **Bookmarks** — pages you've marked (`⌘D` or the 🔖 toolbar button) in the current book.
- **Files** — your library folder tree. Folders and archives (`.cbz` / `.zip`) are visually distinguished.

The pin icon at the top of the sidebar (or `⌃⌘S`) keeps it open
permanently; without pinning, the sidebar slides in as an overlay when
you hover the left edge and slides back out when you move away.

---

## Reading layouts

Three layouts cover all reading styles. Pick directly with
`⌘⇧1` / `⌘⇧2` / `⌘⇧3` — no cycling through unwanted modes.

### Single page (`⌘⇧1`)

![Single page layout](screenshots/01-hero-single-page.png)

One page fills the viewer. Best for portrait scans where each page
stands alone. The next/previous controls advance one page at a time.

### Double page spread (`⌘⇧2`)

![Double page spread layout](screenshots/02-hero-double-page.png)

Two pages side by side, matching the physical book experience. Both
pages decode in parallel so spread refreshes feel snappy. Combined with
RTL reading direction (below), this is the natural manga setup.

### Vertical scroll (`⌘⇧3`)

![Vertical scroll (webtoon) layout](screenshots/03-hero-vertical-strip.png)

Continuous strip from top to bottom — built for webtoons. Pages stream
in lazily as you scroll, and pages that have scrolled past get released
back to placeholders so even a 1000-page strip never pins every image in
memory.

### Right-to-left manga

![Right-to-left manga reading](screenshots/04-hero-rtl-manga.png)

Toggle reading direction (toolbar arrow button) to flip the order for
manga. RTL applies to paged layouts only — vertical scroll always reads
top-to-bottom, so the direction toggle disables itself in vertical mode.

---

## The toolbar

![Floating toolbar with all controls](screenshots/07-toolbar-loaded.png)

Left to right, the toolbar groups are:

1. **Chrome** — Open file (`⌘O`), pin library (`⌃⌘S`), pin toolbar (`⌃⌘T`)
2. **Layout** — Single / Double / Vertical, plus reading direction toggle
3. **Fit & Zoom** — Fit screen / width / height (`⌘1` / `⌘2` / `⌘3`), zoom in/out (`⌘+` / `⌘−`), view-size lock (`⌘L`)
4. **Bookmarks** — Favorite book (`⌘⇧D`), bookmark page (`⌘D`), toggle thumbnail sidebar (`⌃⌘P`)
5. **Navigation** (right edge) — Previous/next volume (`⌘[` / `⌘]`), previous/next page (`←` / `→`)

The toolbar auto-hides when your cursor leaves the top edge. Pin it with
`⌃⌘T` to keep it visible while reading.

---

## Page navigation

![Bottom page slider with quick-jump field](screenshots/11-slider-quickjump.png)

The bottom slider region contains:

- **Volume + page counter** (`Vol 1 / 3 · 1 / 24`) — current sibling volume index plus page within the current book.
- **Quick-jump field** — click and type a page number, press Return to jump.
- **Slider** — drag for visual seek across the whole book.

The slider follows the same auto-hide rules as the toolbar. Hover the
bottom edge to bring it back, or pin both via `⌃⌘T`.

For larger jumps the **Go to Page…** prompt (`⌘G`) takes a number from
1 to the page count and clamps silently on out-of-range input.

---

## Volume continuity

When a series spans multiple files in the same folder, Panely treats
them as sibling volumes and surfaces continuation cards at the
boundaries.

### End of volume

![End-of-volume card with next volume preview](screenshots/08-end-of-volume-card.png)

When you reach the last page of a volume and a next sibling exists, an
**Up next** card appears at the bottom of the viewer. It shows the next
volume's filename so you know what you're about to start. Pressing
`→` or `Space` once (or clicking **Next volume**) loads it.
**Restart** rewinds the current volume to page 1.

### Previous volume

![Previous-volume card](screenshots/09-previous-volume-card.png)

Pressing back (`←`) at page 0 of any volume past the first arms the
**Previous** card. A second back press opens the previous volume.

The card is intent-gated — it doesn't auto-appear on every fresh open
at page 0, so opening Volume 2 cold doesn't badger you about Volume 1.
Only an explicit backward signal surfaces it.

---

## Loading states

![Loading overlay with stage-aware message](screenshots/10-loading-overlay.png)

Heavy operations show a centred overlay with the current stage so you
always know what's happening:

- **Opening…** — initial file inspection
- **Analyzing archive…** — checking for nested archives
- **Extracting archive…** — zip-in-zip unpacking (with a 5 GB safety cap)
- **Scanning folder…** — building the page list from a directory
- **Loading pages…** — decoding image data
- **Building vertical strip…** — laying out the lazy window for webtoon mode

All extraction and decoding runs on background threads, so the UI
remains responsive throughout.

Successfully extracted zip-in-zip archives are cached under
`~/Library/Caches/panely-extraction-cache/` (10 GB budget, LRU eviction),
so reopening the same archive is instant on subsequent launches.

---

## Storage and cache

![Storage settings with extraction cache controls](screenshots/12-storage-cache.png)

Open **File → Settings…** (or **Panely → Settings…**) to inspect and clear
the zip-in-zip extraction cache from the Storage tab.

- **Extraction cache** — total disk space currently used by extracted
  nested archives.
- **Clearable cache** — bytes that can be removed immediately. If the
  current book is open from a cached extraction, that active cache entry
  is kept so reading is not interrupted.
- **Cache limit** — the automatic LRU budget (10 GB).
- **Clear Cache** — removes clearable extraction cache entries and
  refreshes the totals.

The same cleanup is available from **File → Clear Extraction Cache**.
Cache clearing is disabled while a book is loading or extracting.

## Diagnostics

![Diagnostics settings with export controls](screenshots/13-diagnostics-settings.png)

Open **Settings → Diagnostics** and choose **Export Diagnostic Report…** to
create a zip that can be attached to a bug report. It includes:

- App version/build and macOS version.
- Recent Panely log lines.
- Recent open/load events with file paths redacted to filename, extension,
  and type.
- Extraction cache size, current reader settings, and the last reader error.

---

## Bookmarks and favorites

### Favoriting a book

Press `⌘⇧D` (or the ★ toolbar button) while a book is open to add it
to the **Favorites** section of the sidebar. Favorites persist across
launches via security-scoped bookmarks — moving the underlying file
within the same volume continues to work because stale bookmarks are
regenerated on the fly.

### Bookmarking a page

Press `⌘D` (or the 🔖 toolbar button) to mark the current page in the
**Bookmarks** sidebar section. Each book gets its own list (capped at
500 entries per book, 200 books total), keyed by a stable identifier
that survives temp-directory re-extractions of zip-in-zip archives.

Step between bookmarks within the current book with `⌘⇧[` / `⌘⇧]`.

---

## Keyboard shortcuts

The full list lives in
[README → Shortcuts & Gestures](../README.md#shortcuts--gestures).
The most-used:

| Action | Shortcut |
|---|---|
| Next / previous page | `→` / `←` (also `Space` for next) |
| Next / previous volume | `⌘]` / `⌘[` |
| Open file | `⌘O` |
| Go to page… | `⌘G` |
| Bookmark / unbookmark page | `⌘D` |
| Favorite / unfavorite book | `⌘⇧D` |
| Layout: single / double / vertical | `⌘⇧1` / `⌘⇧2` / `⌘⇧3` |
| Fit: screen / width / height | `⌘1` / `⌘2` / `⌘3` |
| Zoom in / out / reset | `⌘+` / `⌘−` / `⌘0` |
| Pin library / toolbar / thumbnails | `⌃⌘S` / `⌃⌘T` / `⌃⌘P` |
| Lock view size | `⌘L` |
