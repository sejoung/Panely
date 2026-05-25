#!/usr/bin/env bash
#
# Regenerate docs/screenshots/*.png from the SnapshotGalleryTests suite.
#
# Why the copy step? The test bundle inherits the host app's sandbox, which
# blocks writes to the repo's docs/ directory. The tests therefore stage
# their PNGs under the sandbox's own Caches dir; this script enables only the
# snapshot suite and copies the results out into the repo after the run.
#
# Usage:
#   scripts/generate-snapshots.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ID="io.github.sejoung.Panely.debug"
SANDBOX_CACHE="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Caches/panely-snapshots"
SNAPSHOT_FLAG="$HOME/Library/Containers/$BUNDLE_ID/Data/tmp/panely-generate-snapshots.flag"
DEST="$PROJECT_ROOT/docs/screenshots"
DERIVED_DATA_PATH="/private/tmp/PanelyDerivedData"
export PANELY_GENERATE_SNAPSHOTS=1

EXPECTED_SNAPSHOTS=(
  "01-hero-single-page.png"
  "02-hero-double-page.png"
  "03-hero-vertical-strip.png"
  "04-hero-rtl-manga.png"
  "05-sidebar-populated.png"
  "06-sidebar-empty.png"
  "07-toolbar-loaded.png"
  "08-end-of-volume-card.png"
  "09-previous-volume-card.png"
  "10-loading-overlay.png"
  "11-slider-quickjump.png"
  "12-storage-cache.png"
  "13-diagnostics-settings.png"
)

cd "$PROJECT_ROOT"

RUN_STAMP="$(mktemp -t panely-snapshots.XXXXXX)"
mkdir -p "$(dirname "$SNAPSHOT_FLAG")"
: > "$SNAPSHOT_FLAG"
trap 'rm -f "$RUN_STAMP" "$SNAPSHOT_FLAG"' EXIT

echo "▶︎ Running snapshot test pass…"
xcodebuild test \
  -project Panely.xcodeproj \
  -scheme Panely \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -only-testing:PanelyTests/SnapshotGalleryTests \
  CODE_SIGN_IDENTITY="-" \
  2>&1 | grep -E "📸|error:|✘ Test|Test run with|^\*\* " \
    | sed '/com\.apple\.linkd\.autoShortcut/d'

if [[ ! -d "$SANDBOX_CACHE" ]]; then
  echo "✗ Sandbox cache dir not found: $SANDBOX_CACHE"
  echo "  (Did the snapshot tests actually run?)"
  exit 1
fi

missing=()
stale=()
for file in "${EXPECTED_SNAPSHOTS[@]}"; do
  path="$SANDBOX_CACHE/$file"
  if [[ ! -s "$path" ]]; then
    missing+=("$file")
  elif [[ ! "$path" -nt "$RUN_STAMP" ]]; then
    stale+=("$file")
  fi
done

actual_count="$(find "$SANDBOX_CACHE" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d '[:space:]')"
expected_count="${#EXPECTED_SNAPSHOTS[@]}"

if [[ "${#missing[@]}" -gt 0 || "${#stale[@]}" -gt 0 || "$actual_count" != "$expected_count" ]]; then
  echo "✗ Snapshot output mismatch in $SANDBOX_CACHE"
  echo "  Expected $expected_count PNGs, found $actual_count."
  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "  Missing:"
    printf '    - %s\n' "${missing[@]}"
  fi
  if [[ "${#stale[@]}" -gt 0 ]]; then
    echo "  Not regenerated in this run:"
    printf '    - %s\n' "${stale[@]}"
  fi
  exit 1
fi

mkdir -p "$DEST"
echo
echo "▶︎ Copying PNGs into $DEST/"
for file in "${EXPECTED_SNAPSHOTS[@]}"; do
  cp -v "$SANDBOX_CACHE/$file" "$DEST/$file"
done

echo
echo "Done."
ls -la "$DEST"
