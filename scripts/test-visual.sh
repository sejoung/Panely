#!/usr/bin/env bash
#
# Run the screenshot comparisons (VisualRegressionTests) against the
# references in PanelyTests/Snapshots/Reference/. Opt-in because rendering and
# comparing every screen costs more than the rest of the suite together. Run it
# after UI changes; re-record intended changes with
# scripts/update-reference-snapshots.sh.
#
# The suite skips itself on a macOS major version other than the references'.
# On a failure the rendered image and a diff are in
#   ~/Library/Containers/io.github.sejoung.Panely.debug/Data/Library/Caches/panely-visual-diffs/
#
# Usage:
#   scripts/test-visual.sh
#   scripts/test-visual.sh -only-testing:'PanelyTests/VisualRegressionTests/sidebarPopulated()'
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# xcodebuild hands TEST_RUNNER_-prefixed variables to the test process
# without the prefix.
export TEST_RUNNER_PANELY_VISUAL_TESTS=1

# Default to the whole visual suite unless the caller picked tests.
selection=(-only-testing:PanelyTests/VisualRegressionTests)
for arg in "$@"; do
  [[ "$arg" == -only-testing:* ]] && selection=()
done

xcodebuild test \
  -project Panely.xcodeproj \
  -scheme Panely \
  -destination 'platform=macOS' \
  -derivedDataPath "${PANELY_DERIVED_DATA_PATH:-/private/tmp/PanelyDerivedData}" \
  CODE_SIGN_IDENTITY="-" \
  ${selection[@]+"${selection[@]}"} \
  "$@" \
  2>&1 | grep -E "error:|✘ |differs from|Rendered:|Diff:|Test run with|^\*\* " \
    | sed '/com\.apple\.linkd\.autoShortcut/d'
