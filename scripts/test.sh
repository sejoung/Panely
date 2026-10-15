#!/usr/bin/env bash
#
# Run the fast test tier — what CI runs and what a plain `xcodebuild test`
# runs. The slow and visual tiers are separate: scripts/test-slow.sh,
# scripts/test-visual.sh.
#
# Usage:
#   scripts/test.sh                                   # whole fast tier
#   scripts/test.sh -only-testing:PanelyTests/FileNodeTests
#   PANELY_DERIVED_DATA_PATH=/path/to/DerivedData scripts/test.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

xcodebuild test \
  -project Panely.xcodeproj \
  -scheme Panely \
  -destination 'platform=macOS' \
  -derivedDataPath "${PANELY_DERIVED_DATA_PATH:-/private/tmp/PanelyDerivedData}" \
  CODE_SIGN_IDENTITY="-" \
  "$@" \
  2>&1 | grep -E "error:|✘ |Test run with|^\*\* " \
    | sed '/com\.apple\.linkd\.autoShortcut/d'
