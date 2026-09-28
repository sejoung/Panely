# UnrarKit (vendored)

Local Swift package that gives Panely CBR/RAR support. Upstream UnrarKit
ships only CocoaPods/Carthage integration, so its sources are vendored here
with a hand-written `Package.swift`.

| Component | Upstream | Version | License |
|-----------|----------|---------|---------|
| Objective-C wrapper (`URKArchive`, `URKFileInfo`) | https://github.com/abbeycode/UnrarKit | 2.10 (master @ 7cd8c32) | BSD — see `LICENSE` |
| UnRAR library (`Sources/UnrarKit/unrar`) | https://www.rarlab.com/rar_add.htm | 7.3.1 (`unrarsrc-7.3.1.tar.gz`) | UnRAR license — see `Sources/UnrarKit/unrar/license.txt` |

UnrarKit 2.10 bundles UnRAR 6.12 (2022). It is built here against UnRAR
7.3.1 instead, for RAR 7 archive support and the security fixes since then.
The UnRAR DLL API that UnrarKit uses (`dll.hpp`) is unchanged between the two.

## Layout

- `Sources/UnrarKit/include/UnrarKit/` — public headers. `dll.hpp` and
  `raros.hpp` live here (not in `unrar/`) because the public UnrarKit headers
  import them as `<UnrarKit/…>`; the unrar sources find them through a header
  search path.
- `Sources/UnrarKit/unrar/` — UnRAR source, unmodified. Only the files of the
  makefile's `lib` target are compiled (`OBJECTS` + `LIB_OBJ`); the others are
  `#include`d by those or belong to the CLI/Windows builds and are excluded in
  `Package.swift`. Built with `-DRARDLL -DSILENT`.
- The upstream `UnrarKitResources` bundle (English-only error strings) is not
  included; UnrarKit falls back to the main bundle, whose lookups return the
  English keys unchanged.

## Local patches

Search for `Panely patch` to find them.

1. `URKArchive -isSolid` — exposes the archive-level `ROADF_SOLID` flag.
2. `URKArchive -closeFile` — frees `ArcName` with `free()` (it is allocated by
   `strdup()`; upstream used `delete`).

## Thread safety

UnRAR keeps its error state in a process-wide global (`ErrHandler`), so
concurrent operations on *different* archives corrupt each other's results.
Callers must serialise every UnrarKit call; Panely's `RARArchiveReader` does
this with a single shared lock.

## Updating UnRAR

1. Download the new `unrarsrc-x.y.z.tar.gz` from rarlab.com.
2. Replace `Sources/UnrarKit/unrar/` with the new sources, then move `dll.hpp`
   and `raros.hpp` into `include/UnrarKit/`.
3. Diff the makefile's `OBJECTS`/`LIB_OBJ` against the compiled set and update
   `unrarNonLibSources` in `Package.swift`.
4. `swift build` here, then run Panely's tests.
