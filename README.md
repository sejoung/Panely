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

Panely is a distraction-free comic reader that disappears when you don't need it.
No toolbars unless you ask. No thumbnails stealing attention. Just the page.

The UI is built to follow the content — toolbar auto-hides, sidebar toggles,
and the viewer always takes the maximum space available. Dark mode is default
because reading comics in a bright chrome is fatiguing.

## Features

### Reading
- Open **folders**, **CBZ**, or **ZIP** archives
- **Series root auto-detection** — pick a parent folder and the first volume opens
- **Single page** / **double page spread** layouts
- **LTR / RTL** reading direction (manga-friendly)
- **Fit to screen** / **Fit to width**
- **Pinch zoom** (0.5× – 5×) with double-click reset
- **Image preloading** (±2 pages ahead) for instant page flips
- **Natural file sort** (1, 2, 10 — not 1, 10, 2)

### Navigation
- **Keyboard-first** — ← → for pages, ⌘[ ⌘] for volumes, ⌘1/⌘2 for fit modes
- **Library sidebar** — hierarchical file tree of the current series
- **Volume navigation** — jump between books in the same folder
- **Recent items** — File &gt; Open Recent persists across launches (security-scoped bookmarks)

### State
- **Resume where you left off** — per-book page memory
- **Layout + direction persistence** — pick once, remembered forever
- **Sandboxed** — no arbitrary disk access; only folders/files you pick

## Requirements

- **macOS 14** (Sonoma) or later
- **Xcode 16** or later (for building from source)

## Getting Started

### Clone & Run

```bash
git clone https://github.com/sejoung/Panely.git
cd Panely
open Panely.xcodeproj
```

Select the **Panely** scheme and press **⌘R**.

### Dependencies

Panely uses Swift Package Manager. The only external dependency is:

- **[ZIPFoundation](https://github.com/weichsel/ZIPFoundation)** — CBZ/ZIP archive reading

Xcode will resolve packages automatically on first build.

## Keyboard Shortcuts

| Shortcut | Action |
|:---------|:-------|
| `⌘O` | Open folder / CBZ / ZIP |
| `←` / `→` | Previous / next page (direction-aware) |
| `Space` | Next page |
| `⌘[` / `⌘]` | Previous / next volume |
| `⌘1` / `⌘2` | Fit to screen / fit to width |
| `⌃⌘S` | Toggle library sidebar |
| `Double-click` on image | Toggle 1× ↔ 2× zoom |
| Trackpad pinch | Zoom in/out |

## Project Structure

```
Panely/
├── PanelyApp.swift            # @main, scene + menu commands
├── ContentView.swift
├── DesignSystem/
│   ├── Tokens/                # Color / Spacing / Typography / Motion
│   └── Primitives/            # Icon button, slider
├── Features/
│   ├── Reader/                # Viewer, toolbar, view model
│   │   ├── ReaderViewModel.swift
│   │   ├── ViewerContainer.swift
│   │   ├── PanelyToolbar.swift
│   │   ├── ReaderScene.swift
│   │   ├── PageLayout.swift
│   │   ├── ReadingDirection.swift
│   │   └── FitMode.swift
│   └── Library/               # Sidebar, recent items
│       ├── LibrarySidebar.swift
│       ├── FileNode.swift
│       ├── RecentItem.swift
│       └── RecentItemsStore.swift
└── Core/
    └── Comic/                 # Loaders, image I/O
        ├── ComicPage.swift
        ├── ComicSource.swift
        ├── ComicPageSource.swift
        ├── FolderLoader.swift
        ├── CBZLoader.swift
        ├── ArchiveReader.swift
        └── ImageLoader.swift

docs/
├── panely_prd_product_requirements_document.md
├── panely_design_system_mac_os.md
└── icon/
    └── panely-icon-stacked.svg

scripts/
└── generate-app-icon.sh       # SVG → .icns pipeline
```

## Architecture Notes

- **`@Observable` + `@MainActor`** — `ReaderViewModel` is main-actor isolated,
  handling UI state and orchestrating async loads.
- **`nonisolated` Core types** — `ComicPage`, `FolderLoader`, `CBZLoader`,
  `ImageLoader` run off-main for file I/O via `Task.detached`.
- **`actor ArchiveReader`** — thread-safe wrapper around ZIPFoundation's
  `Archive`, serializes entry reads.
- **`NSCache`-based image cache** — per-page decoded `NSImage`s, automatic
  memory-pressure eviction.
- **Security-scoped bookmarks** — Recent items persist across launches;
  scope lifecycle is tracked at the root URL to allow free sibling navigation
  within an opened tree.

## Regenerating the App Icon

If you edit `docs/icon/panely-icon-stacked.svg`, regenerate the icns:

```bash
scripts/generate-app-icon.sh
```

This rasterizes the SVG at all required sizes (16–1024), embeds sRGB
profiles, and produces `Panely/AppIcon.icns`. Requires `librsvg` and
`imagemagick` from Homebrew.

## Releasing

Releases are built and published automatically by
[`.github/workflows/release.yml`](.github/workflows/release.yml) when a tag
matching `v*` is pushed.

```bash
# bump MARKETING_VERSION in Panely.xcodeproj if needed, then:
git tag v1.0.0
git push origin v1.0.0
```

The workflow will:

1. Build `Panely.app` with ad-hoc signing on a `macos-latest` runner.
2. Zip the bundle with `ditto` (preserves resource forks).
3. Create a GitHub Release with auto-generated notes and the zip attached.

Since the build uses ad-hoc signing (no Apple Developer account required),
first-time users will need to right-click the app and choose **Open** to
bypass Gatekeeper.

### CI / storage

- **CI** runs on every push/PR, builds Debug only, and **uploads no artifacts**
  — storage footprint is essentially zero.
- **Releases** attach a single zip (typically &lt;10 MB) to GitHub Releases.
- **SPM cache** speeds up subsequent runs; invalidates on `Package.resolved`
  or `project.pbxproj` changes.

## Roadmap

- [ ] **Vertical scroll mode** — webtoon-style continuous scroll
- [ ] **Thumbnail sidebar** — page-level preview panel
- [ ] **Favorites / bookmarks** — mark specific pages
- [ ] **AppKit-backed viewer** — for heavy image performance tuning
- [ ] **Persistent library root** — set a home library folder
- [ ] **WebP** / **HEIC** first-class support

## Contributing

Contributions are welcome. Please keep in mind:

- **Respect the design principle** — distraction-free, minimal UI first.
  Any change that adds permanent chrome should have a very good reason.
- **macOS conventions** — SF Symbols for icons, native menus, keyboard-first.
- **Sandbox-compliant** — no paths the user hasn't granted.

Open an issue or PR at [github.com/sejoung/Panely](https://github.com/sejoung/Panely).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
