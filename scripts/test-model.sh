#!/usr/bin/env bash
#
# Run the tests that use the real translation model (Gemma 4 E2B through
# llama.cpp): GemmaTranslatorIntegrationTests. Off in every other run — they
# load 3.3 GB. See PanelyTests/TestTiers.swift.
#
# The test host is sandboxed and finds the model where the Debug app keeps
# it (downloaded from Settings › Experimental). --model hard-links a file you
# already have into that place first (no copy; the Debug app sees it too).
#
# Usage:
#   scripts/test-model.sh [--model PATH] [xcodebuild args…]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

SANDBOX="$HOME/Library/Containers/io.github.sejoung.Panely.debug/Data"
# Where TranslationModelFiles looks (its id and file name).
MODEL_DIR="$SANDBOX/Library/Application Support/panely-models/gemma-4-e2b-it-q4_0"
MODEL_FILE="$MODEL_DIR/gemma-4-E2B_q4_0-it.gguf"

if [[ "${1:-}" == "--model" ]]; then
  mkdir -p "$MODEL_DIR"
  if [[ ! -e "$MODEL_FILE" ]]; then
    ln "$2" "$MODEL_FILE" 2>/dev/null || cp "$2" "$MODEL_FILE"
  fi
  shift 2
fi
if [[ ! -e "$MODEL_FILE" ]]; then
  echo "✗ No model at $MODEL_FILE — download it in the Debug app or pass --model PATH" >&2
  exit 1
fi

# xcodebuild hands TEST_RUNNER_-prefixed variables to the test process
# without the prefix.
export TEST_RUNNER_PANELY_MODEL_TESTS=1

xcodebuild test \
  -project Panely.xcodeproj \
  -scheme Panely \
  -destination 'platform=macOS' \
  -derivedDataPath "${PANELY_DERIVED_DATA_PATH:-/private/tmp/PanelyDerivedData}" \
  CODE_SIGN_IDENTITY="-" \
  -only-testing:PanelyTests/GemmaTranslatorIntegrationTests \
  "$@" \
  2>&1 | grep -E "error:|✘ |GEMMA|Test run with|^\*\* " \
    | sed '/com\.apple\.linkd\.autoShortcut/d'
