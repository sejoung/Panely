<p align="center">
  <img src="docs/icon/panely-icon-stacked.svg" width="160" alt="Panely">
</p>

<h1 align="center">Panely</h1>

<p align="center">
  A minimal, fast comic &amp; image viewer for macOS.<br>
  <em>macOS를 위한 미니멀한 만화/이미지 뷰어</em>
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-blue">
  <img alt="swift" src="https://img.shields.io/badge/swift-5-orange">
  <img alt="license" src="https://img.shields.io/badge/license-Apache%202.0-green">
  <a href="https://github.com/sejoung/Panely/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/sejoung/Panely/actions/workflows/ci.yml/badge.svg"></a>
</p>

---

## Overview

Panely is a distraction-free comic reader that gets out of your way. The UI
hides when you don't need it, the sidebar toggles in and out, and the viewer
always takes the maximum space available. Dark mode is enforced because
reading in bright chrome is fatiguing.

The viewer core is AppKit-backed (`NSScrollView` + layer-backed image views)
so pinch-zoom, scroll, and re-centering stay native and smooth even on large
pages.

## Features

### Reading
- **Single page** and **double-page spread** layouts
- **Left-to-right** or **right-to-left** reading (manga-friendly)
- **Fit to screen** / **fit to width** — stable across toggles, with no
  feedback drift on repeated mode switches
- **Auto-refit on viewport resize** — when the window or sidebar size changes,
  the image instantly snaps to the new fit. Manual zoom is preserved across
  resizes (only the next reset is recalibrated)
- **Pinch zoom** via trackpad, **double-click** to toggle 1× ↔ 2×
- **Auto-centering** — image stays centered when the viewport is larger
- **Preload ±2 pages** so the next flip is instant
- **Progress overlay** — stage-aware messages (Opening / Extracting / Loading)
  while big archives are being processed, all on background threads

### File support
- Open **folder**, **CBZ**, or **ZIP**
- **Series-root auto-detection** — pick a folder of volumes and the first one opens
- **Nested archive extraction** (up to 3 levels deep, recursive)
- Natural filename sort (`1, 2, 10` — not `1, 10, 2`)
- Filters non-image files and hidden entries

### Navigation
- **Keyboard-first** — `← → Space` for pages, `⌘[ ⌘]` for volumes,
  `⌘1 ⌘2` for fit modes, `⌃⌘S` to pin the sidebar, `⌘O` to open
- **Auto-hide library sidebar** — hidden by default to give the page maximum
  room. Hover the **left edge** (200 ms) and the sidebar slides in as an
  overlay (with drop shadow, no page shift). Mouse-out auto-dismisses after
  300 ms; `ESC` dismisses immediately
- **Pin mode** — click the pin button in the sidebar header (or press `⌃⌘S`)
  to lock it into push-layout where it always stays visible. Pin state
  persists across launches
- **Sidebar tree** — folders and archives are visually disambiguated:
  `folder` vs `doc.zipper` icons, plus a faint `.cbz` / `.zip` suffix on
  archives for quick reading
- **Volume navigation** between sibling books in the same folder
- **Recent items** — persistent across launches via security-scoped bookmarks,
  shown with the same icon scheme
- **Folder access grant** — when a single file is opened and siblings aren't
  visible, the sidebar offers a one-click prompt to pick the enclosing folder
- **Window controls** — with the title bar hidden, the top 28 px strip still
  supports native drag-to-move and double-click-to-zoom (respecting the
  system's `AppleActionOnDoubleClick` preference); an open-hand cursor
  makes the draggable region obvious

### State persistence
- **Resume where you left off** — per-book page memory with a stable key that
  survives temp-directory extractions
- **Layout + direction + fit mode + sidebar pin state** all persisted (the
  legacy `panely.sidebarVisible` key auto-migrates to the new pin flag)
- Entirely sandbox-compliant (user-selected files + app-scoped bookmarks)

## Requirements

- **macOS 14** (Sonoma) or later
- **Xcode 16** or later (for building from source)

## Getting Started

```bash
git clone https://github.com/sejoung/Panely.git
cd Panely
open Panely.xcodeproj
```

Select the **Panely** scheme and press **⌘R**.

### Dependency

Panely uses Swift Package Manager. The only external dependency is:

- **[ZIPFoundation](https://github.com/weichsel/ZIPFoundation)** — CBZ/ZIP archive reading &amp; extraction

Xcode resolves it automatically on first build.

## Shortcuts &amp; Gestures

| Input | Action |
|:------|:-------|
| `⌘O` | Open folder / CBZ / ZIP |
| `←` / `→` | Previous / next page (direction-aware) |
| `Space` | Next page |
| `⌘[` / `⌘]` | Previous / next volume |
| `⌘1` / `⌘2` | Fit to screen / fit to width |
| `⌃⌘S` | Pin / unpin library sidebar |
| Hover left edge | Reveal sidebar as overlay (auto-hide mode) |
| `ESC` | Dismiss sidebar overlay (when unpinned) |
| Double-click on image | Toggle 1× ↔ 2× zoom |
| Trackpad pinch | Zoom in / out |
| Drag top 28 px strip | Move window |
| Double-click top 28 px strip | Zoom / minimize window (per system preference) |

## Testing

```bash
xcodebuild test \
  -project Panely.xcodeproj \
  -scheme Panely \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-"
```

**63 tests across 18 suites** cover:

- Pure data types (`ComicPage`, `ComicSource`, `RecentItem`, enum raw values)
- Natural-sort contract (Foundation behaviour Panely relies on)
- **Position-key stability** across temp-dir extractions (zip-in-zip scenarios)
- **FolderLoader** integration with real temp directories
- **FileNode.loadTree** scanning, sorting, empty/unreadable cases, and the
  `fileExtension` exposure used for sidebar badges
- **CBZLoader** integration with programmatically-built zip fixtures,
  including recursive nested-archive extraction
- **FitCalculator** pure math across aspect ratios and zero-inputs
- **NSScrollView** magnification stability on repeated fit-mode toggles
- **Viewer resize auto-fit** — magnification follows the viewport when
  unzoomed, preserves manual zoom on resize, releases its
  `frameDidChangeNotification` observer on Coordinator deinit
- **CenteringClipView** — document centering when smaller than the viewport
- **SidebarMode** — pure value-type covering pinned / overlay state
  transitions (default unpinned, pin idempotency, overlay no-op while
  pinned, unpin clears any lingering overlay)

Tests are organized to mirror the source tree under `PanelyTests/Core/`,
`PanelyTests/Features/Library/`, and `PanelyTests/Features/Reader/`, with
shared fixtures in `PanelyTests/TestFixtures.swift`.

`RecentItem.Codable` includes a `decodeIfPresent` path for `isDirectory` so
old stored entries survive a schema bump.

## Project Structure

```
Panely/
├── PanelyApp.swift                     # @main, commands, window style
├── ContentView.swift
├── AppIcon.icns                        # generated from docs/icon/*.svg
├── DesignSystem/
│   ├── Tokens/                         # Color / Spacing / Typography / Motion
│   └── Primitives/                     # Icon button, slider
├── Features/
│   ├── Reader/
│   │   ├── ReaderViewModel.swift       # @Observable @MainActor
│   │   ├── ReaderScene.swift           # ZStack layout + hot-edge reveal
│   │   ├── ViewerContainer.swift       # SwiftUI shell around AppKit viewer
│   │   ├── PanelyToolbar.swift
│   │   ├── LoadingOverlay.swift
│   │   ├── PageLayout.swift / ReadingDirection.swift / FitMode.swift
│   │   ├── FitCalculator.swift         # pure magnification math
│   │   ├── PositionKey.swift           # stable per-book position keys
│   │   └── SidebarMode.swift           # pinned / overlay state value-type
│   └── Library/
│       ├── LibrarySidebar.swift        # pin button + extension badge row
│       ├── FileNode.swift              # iconName + fileExtension
│       ├── RecentItem.swift
│       └── RecentItemsStore.swift
└── Core/
    └── Comic/
        ├── ComicPage.swift / ComicSource.swift / ComicPageSource.swift
        ├── FolderLoader.swift
        ├── CBZLoader.swift             # flat + recursive-nested extraction
        ├── ArchiveReader.swift         # actor around ZIPFoundation.Archive
        └── ImageLoader.swift           # async NSImage with Task.detached

PanelyTests/
├── TestFixtures.swift                  # shared temp-dir / zip helpers
├── Core/Comic/                         # ComicModel, Loader extension, FolderLoader, CBZLoader
├── Features/Library/                   # RecentItem, FileNode
└── Features/Reader/                    # enums, NaturalSort, PositionKey, FitCalculator,
                                        # FitMagnificationStability, CenteringClipView,
                                        # ViewerResizeFit, SidebarMode

docs/
├── panely_prd_product_requirements_document.md
├── panely_design_system_mac_os.md
└── icon/panely-icon-stacked.svg

scripts/
├── generate-app-icon.sh                # SVG → .icns pipeline
└── release.sh                          # bump + tag + push automation

.github/workflows/
├── ci.yml                              # build + test on push/PR
└── release.yml                         # zip + GitHub Release on v* tag

Info.plist                              # bundle icon reference
Panely.entitlements                     # sandbox + user-selected + bookmarks
```

## Architecture Notes

- **`@Observable` + `@MainActor`** — `ReaderViewModel` is main-actor isolated
  and orchestrates async loads via explicit stage messages to drive the
  loading overlay.
- **`nonisolated` core types** — `ComicPage`, `FolderLoader`, `CBZLoader`,
  `ImageLoader`, `FitCalculator`, `PositionKey` run off-main via
  `Task.detached`.
- **`actor ArchiveReader`** — wraps ZIPFoundation's `Archive` for
  serialised, thread-safe entry reads.
- **AppKit viewer core** — `ViewerContainer` is SwiftUI, but the scrollable
  zoomable stage is an `NSViewRepresentable` wrapping `NSScrollView` +
  `CenteringClipView` + a custom `ImageStackView`. `acceptsFirstResponder`
  is disabled so keyboard events still flow to SwiftUI's `.onKeyPress`.
- **`CenteringClipView`** overrides `constrainBoundsRect(_:)` to center the
  document when the viewport is larger — keeps the image in the middle when
  the sidebar is toggled.
- **`TitleBarPassthrough`** — a thin NSView overlaying the top 28 px of the
  viewer. `mouseDownCanMoveWindow = true` gives native window drag, an
  `NSTrackingArea` with `.cursorUpdate` shows the open-hand cursor, and a
  `mouseDown` override handles double-click zoom via
  `AppleActionOnDoubleClick`. The overlay uses `.ignoresSafeArea(edges: .top)`
  so it lines up with the actual window edge under `.hiddenTitleBar`.
- **`FitCalculator`** — physical viewport (`scrollView.contentSize`) is
  magnification-invariant, so toggling fit modes produces stable
  magnifications (no feedback loop).
- **Viewer auto-refit on resize** — `AppKitImageScroller` subscribes to its
  `NSScrollView`'s `frameDidChangeNotification`. The handler hops onto
  `MainActor`, recomputes the fit, and only writes magnification when the
  user has not manually zoomed (so resizing the window doesn't clobber
  intentional zoom). The Coordinator removes its observer on deinit.
- **`SidebarMode`** — a tiny pure value-type owning `pinned` and
  `overlayVisible`; `ReaderViewModel` holds an instance and persists only
  `pinned`. UI composes it via `sidebarVisible` (computed). Hot-edge hover
  reveal lives in `ReaderScene` as a small `HotEdgeReveal` SwiftUI view that
  fires `revealSidebarOverlay()` after a 200 ms delay; mouse-out from the
  overlay schedules a 300 ms dismiss.
- **`PositionKey.make(for:opened:tempRoot:)`** — for sources extracted to
  `/tmp`, the key is derived from the opened URL plus the relative path
  inside the temp root so reading progress survives re-extraction.
- **`NSCache`-backed image cache** — per-page decoded `NSImage`s with
  automatic memory-pressure eviction; preload runs a cancellable
  `Task` around the current page ±2.
- **Security-scoped bookmarks** — Recent items persist across launches
  because we create `.withSecurityScope` bookmarks and resolve them on click.
  Scope lifecycle is tracked at the root URL so sibling navigation within a
  selected tree doesn't require re-prompting.
- **Distraction-free chrome** — `.windowStyle(.hiddenTitleBar)` and
  `.preferredColorScheme(.dark)` make the whole window behave like the
  viewer itself; traffic-light buttons remain but the title text is gone.

## Releasing

Releases are built and published automatically by
[`.github/workflows/release.yml`](.github/workflows/release.yml) when a tag
matching `v*` is pushed.

The easiest way is the helper script:

```bash
scripts/release.sh patch   # 1.0.0 → 1.0.1
scripts/release.sh minor   # 1.0.1 → 1.1.0
scripts/release.sh major   # 1.1.0 → 2.0.0
scripts/release.sh 1.2.3   # explicit version
scripts/release.sh         # interactive prompt
```

The script:

1. Checks the working tree is clean, on `main`, in sync with origin, and the
   tag is free on both local and remote.
2. Runs local tests (set `SKIP_TESTS=1` to skip).
3. Bumps `MARKETING_VERSION` in `project.pbxproj`.
4. Commits (`chore: release vX.Y.Z`) and creates an annotated tag.
5. Pushes `main` and the tag (set `NO_PUSH=1` to stop before pushing).

The release commit message is matched by CI's `if:` filter so the bump
itself doesn't re-trigger the build pipeline — the tag push kicks off
`release.yml` only.

If you prefer doing it by hand:

```bash
git tag v1.0.0
git push origin v1.0.0
```

### CI / storage

- **CI** runs on every push/PR (skips `**/*.md` and `docs/**`), builds
  Debug with ad-hoc signing, runs all 63 tests, and uploads no artifacts —
  storage footprint is essentially zero.
- **Releases** attach a single zip (~5–10 MB) to GitHub Releases using
  `ditto` so resource forks are preserved.
- **SPM cache** speeds up subsequent runs; invalidates on `Package.resolved`
  or `project.pbxproj` changes.

## Regenerating the App Icon

If you edit `docs/icon/panely-icon-stacked.svg`, regenerate the icns:

```bash
scripts/generate-app-icon.sh
```

This rasterises the SVG at all required sizes (16–1024), embeds sRGB
profiles via ImageMagick, and produces `Panely/AppIcon.icns` via `iconutil`.
Requires `librsvg` and `imagemagick` from Homebrew.

## Roadmap

- [x] AppKit-backed viewer with native magnification
- [x] Nested-archive support (zip-in-zip)
- [x] Position memory stable across temp extractions
- [x] Library sidebar with folder access grant
- [x] Recent items with persistent bookmarks
- [x] Loading overlay with stage messages
- [ ] **Vertical scroll mode** — webtoon-style continuous scroll
- [ ] **Thumbnail sidebar** — page-level preview panel
- [ ] **Bookmarks / favorites** — pin specific pages or books
- [ ] **Persistent library root** — set a home library folder once
- [ ] **WebP / HEIC** — verify first-class support end-to-end

## Contributing

Contributions are welcome. Please keep in mind:

- **Respect the design principle** — distraction-free, minimal UI first.
  Any change that adds permanent chrome should have a very good reason.
- **macOS conventions** — SF Symbols for icons, native menus, keyboard-first.
- **Sandbox-compliant** — no paths the user hasn't granted.
- **Tested logic** — any non-trivial pure function should land with a test
  in `PanelyTests/`.

Open an issue or PR at [github.com/sejoung/Panely](https://github.com/sejoung/Panely).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
