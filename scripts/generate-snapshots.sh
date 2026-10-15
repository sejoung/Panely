#!/usr/bin/env bash
#
# Regenerate docs/screenshots/*.png from the SnapshotGalleryTests suite.
#
# Why the copy step? The test bundle inherits the host app's sandbox, which
# blocks writes to the repo's docs/ directory. The tests therefore stage
# their PNGs under the sandbox's own Caches dir; this script enables only the
# snapshot suite and copies the results out into the repo after the run.
#
# The suite is enabled for this run's test process only: xcodebuild hands
# TEST_RUNNER_-prefixed variables to the tests with the prefix dropped. (A
# flag file in the shared sandbox would enable it for every test run on the
# machine.)
#
# Usage:
#   scripts/generate-snapshots.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ID="io.github.sejoung.Panely.debug"
SANDBOX_CACHE="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Caches/panely-snapshots"
DEST="$PROJECT_ROOT/docs/screenshots"
DERIVED_DATA_PATH="/private/tmp/PanelyDerivedData"
export TEST_RUNNER_PANELY_GENERATE_SNAPSHOTS=1

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
  "14-toolbar-spread-offset.png"
  "15-library-settings.png"
  "16-general-settings.png"
  "17-translation-reading.png"
  "18-translation-before-after.png"
  "19-translation-panel.png"
  "20-translation-balloon-popover.png"
  "21-translation-export-sheet.png"
  "22-jobs-window.png"
  "23-experimental-settings.png"
  "24-ai-chat-sheet.png"
)

cd "$PROJECT_ROOT"

RUN_STAMP="$(mktemp -t panely-snapshots.XXXXXX)"
trap 'rm -f "$RUN_STAMP"' EXIT

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
