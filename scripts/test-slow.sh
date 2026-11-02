#!/usr/bin/env bash
#
# Run the fast tier plus the slow tier: real FSEvents streams (each waits out
# the stream's 1 s latency), real Vision OCR, and the randomized sequences
# over every seed. Worth running before a release or after touching the
# library watcher, the translation pipeline or the stores. See
# PanelyTests/TestTiers.swift.
#
# Usage:
#   scripts/test-slow.sh                              # fast + slow tiers
#   scripts/test-slow.sh -only-testing:PanelyTests/LiveLibraryDirectoryWatcherTests
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# xcodebuild hands TEST_RUNNER_-prefixed variables to the test process
# without the prefix.
export TEST_RUNNER_PANELY_SLOW_TESTS=1

exec "$SCRIPT_DIR/test.sh" "$@"
