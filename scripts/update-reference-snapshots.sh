#!/usr/bin/env bash
#
# Re-record the reference PNGs that VisualRegressionTests compares against
# (PanelyTests/Snapshots/Reference/). Run after an intended UI change, then
# review the changed PNGs in the diff before committing them.
#
# Same sandbox dance as generate-snapshots.sh: the test bundle can't write
# into the repo, so it stages the PNGs (and a manifest naming the macOS major
# version they were recorded on) under the Debug app sandbox's caches, and
# this script copies them out.
#
# Recording mode reaches only this run's test process: xcodebuild hands
# TEST_RUNNER_-prefixed variables to the tests with the prefix dropped. (A
# flag file in the shared sandbox would switch every test run on the machine
# into recording.)
#
# Usage:
#   scripts/update-reference-snapshots.sh
#   PANELY_DERIVED_DATA_PATH=/path/to/DerivedData scripts/update-reference-snapshots.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ID="io.github.sejoung.Panely.debug"
SANDBOX_CACHE="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Caches/panely-reference-snapshots"
DEST="$PROJECT_ROOT/PanelyTests/Snapshots/Reference"
DERIVED_DATA_PATH="${PANELY_DERIVED_DATA_PATH:-/private/tmp/PanelyDerivedData}"
export TEST_RUNNER_PANELY_RECORD_REFERENCE_SNAPSHOTS=1

cd "$PROJECT_ROOT"

rm -rf "$SANDBOX_CACHE"

echo "▶︎ Recording reference snapshots…"
xcodebuild test \
  -project Panely.xcodeproj \
  -scheme Panely \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -only-testing:PanelyTests/VisualRegressionTests \
  CODE_SIGN_IDENTITY="-" \
  2>&1 | grep -E "📸|error:|✘ Test|Test run with|^\*\* " \
    | sed '/com\.apple\.linkd\.autoShortcut/d'

if [[ ! -f "$SANDBOX_CACHE/reference-snapshots.json" ]]; then
  echo "✗ Nothing recorded in $SANDBOX_CACHE"
  echo "  (Did the visual regression tests actually run?)"
  exit 1
fi

mkdir -p "$DEST"
rm -f "$DEST"/reference-*.png
cp -v "$SANDBOX_CACHE"/reference-*.png "$SANDBOX_CACHE/reference-snapshots.json" "$DEST/"

echo
echo "Done. Review the changes before committing:"
echo "  git status -- PanelyTests/Snapshots/Reference"
