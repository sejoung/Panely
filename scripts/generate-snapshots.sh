#!/usr/bin/env bash
#
# Regenerate docs/screenshots/*.png from the SnapshotGalleryTests suite.
#
# Why the copy step? The test bundle inherits the host app's sandbox, which
# blocks writes to the repo's docs/ directory. The tests therefore stage
# their PNGs under the sandbox's own Caches dir; this script copies the
# results out into the repo after the run.
#
# Usage:
#   scripts/generate-snapshots.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ID="io.github.sejoung.Panely"
SANDBOX_CACHE="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Caches/panely-snapshots"
DEST="$PROJECT_ROOT/docs/screenshots"

cd "$PROJECT_ROOT"

echo "▶︎ Running snapshot suite…"
xcodebuild test \
  -project Panely.xcodeproj \
  -scheme Panely \
  -destination 'platform=macOS' \
  -only-testing:PanelyTests/SnapshotGalleryTests \
  CODE_SIGN_IDENTITY="-" \
  2>&1 | grep -E "📸|error:|✘ Test|Test run with|^\*\* "

if [[ ! -d "$SANDBOX_CACHE" ]]; then
  echo "✗ Sandbox cache dir not found: $SANDBOX_CACHE"
  echo "  (Did the snapshot tests actually run?)"
  exit 1
fi

mkdir -p "$DEST"
echo
echo "▶︎ Copying PNGs into $DEST/"
cp -v "$SANDBOX_CACHE"/*.png "$DEST/"

echo
echo "Done."
ls -la "$DEST"
