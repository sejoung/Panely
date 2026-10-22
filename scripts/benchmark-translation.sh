#!/usr/bin/env bash
#
# Time the translation pipeline: each stage on its own (page read, decode,
# balloon detection, OCR, the full analysis, loading the model and
# translating balloons in chunks) and whole translation jobs, the way the app
# runs them.
#
# Runs PanelyTests/TranslationBenchmarkTests, which is off in every ordinary
# test run: it's enabled for this run's test process only, through
# TEST_RUNNER_-prefixed variables (xcodebuild passes them on to the tests
# with the prefix dropped).
#
# Needs the translation model (Gemma 4 E2B GGUF) in the test host's sandbox:
# downloaded once in the Debug app (Settings › Experimental), or linked in
# from a file you already have with --model. What couldn't run is reported
# as skipped.
#
# The test host is sandboxed, so a --book is copied into the sandbox's
# temporary folder for the run and deleted afterwards. The book itself is
# only read. --model is hard-linked (no copy) into the sandbox's Application
# Support, where the Debug app finds it too.
#
# Usage:
#   scripts/benchmark-translation.sh [options]
#
# Options:
#   --book PATH          also run a real book (a .zip/.cbz)
#   --book-pages N       pages of the book to translate (default 60)
#   --book-first N       first page (default 0)
#   --book-pair SRC-DST  the book's language pair (default ko-ja)
#   --pages N            synthetic pages (default 40)
#   --parts LIST         any of stages, job (default stages,job)
#   --model PATH         the model file (gemma-4-E2B_q4_0-it.gguf) to link in
#   --samples N          print N of the job's balloons and their translations
#   --runs N             repeat the test run N times (default 1)
#   --label TEXT         tag on every result line
#   --optimize           build with SWIFT_OPTIMIZATION_LEVEL=-O (Debug otherwise)
#   --derived-data PATH  (default /private/tmp/PanelyBenchmarkDerivedData)
#   --project-root PATH  checkout to build (default this script's)
#   --skip-build         reuse the last build in --derived-data
#   --out FILE           also append the result lines to FILE
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="/private/tmp/PanelyBenchmarkDerivedData"
BUNDLE_ID="io.github.sejoung.Panely.debug"
SANDBOX="$HOME/Library/Containers/$BUNDLE_ID/Data"
RESULTS="$SANDBOX/Library/Caches/panely-benchmark/results.txt"

BOOK=""
BOOK_PAGES=60
BOOK_FIRST=0
BOOK_PAIR="ko-ja"
PAGES=40
PARTS="stages,job"
MODEL=""
SAMPLES=0
RUNS=1
LABEL="run"
OPTIMIZE=0
SKIP_BUILD=0
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --book) BOOK="$2"; shift 2 ;;
    --book-pages) BOOK_PAGES="$2"; shift 2 ;;
    --book-first) BOOK_FIRST="$2"; shift 2 ;;
    --book-pair) BOOK_PAIR="$2"; shift 2 ;;
    --pages) PAGES="$2"; shift 2 ;;
    --parts) PARTS="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --samples) SAMPLES="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --optimize) OPTIMIZE=1; shift ;;
    --derived-data) DERIVED_DATA_PATH="$2"; shift 2 ;;
    --project-root) PROJECT_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

BUILD_SETTINGS=(CODE_SIGN_IDENTITY="-")
if [[ "$OPTIMIZE" == 1 ]]; then
  BUILD_SETTINGS+=(SWIFT_OPTIMIZATION_LEVEL=-O)
fi
XCODEBUILD_ARGS=(
  -project "$PROJECT_ROOT/Panely.xcodeproj"
  -scheme Panely
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED_DATA_PATH"
)

if [[ "$SKIP_BUILD" == 0 ]]; then
  echo "▶︎ Building $PROJECT_ROOT for testing…"
  xcodebuild build-for-testing "${XCODEBUILD_ARGS[@]}" "${BUILD_SETTINGS[@]}" -quiet 2>&1 \
    | grep -E "error:|\*\* " || true
fi

export TEST_RUNNER_PANELY_BENCHMARK=1
export TEST_RUNNER_PANELY_BENCHMARK_LABEL="$LABEL"
export TEST_RUNNER_PANELY_BENCHMARK_PAGES="$PAGES"
export TEST_RUNNER_PANELY_BENCHMARK_PARTS="$PARTS"
export TEST_RUNNER_PANELY_BENCHMARK_SAMPLES="$SAMPLES"
export TEST_RUNNER_PANELY_BENCHMARK_BOOK=""

if [[ -n "$MODEL" ]]; then
  # Where TranslationModelFiles looks (its id and file name).
  MODEL_DIR="$SANDBOX/Library/Application Support/panely-models/gemma-4-e2b-it-q4_0"
  mkdir -p "$MODEL_DIR"
  if [[ ! -e "$MODEL_DIR/gemma-4-E2B_q4_0-it.gguf" ]]; then
    ln "$MODEL" "$MODEL_DIR/gemma-4-E2B_q4_0-it.gguf" 2>/dev/null || cp "$MODEL" "$MODEL_DIR/gemma-4-E2B_q4_0-it.gguf"
  fi
fi

SANDBOX_BOOK_DIR=""
cleanup() {
  if [[ -n "$SANDBOX_BOOK_DIR" ]]; then rm -rf "$SANDBOX_BOOK_DIR"; fi
}
trap cleanup EXIT

ONLY_TESTING=(-only-testing:PanelyTests/TranslationBenchmarkTests/syntheticJapaneseToKorean\(\))
if [[ -n "$BOOK" ]]; then
  # Not `panely-`: the app sweeps that prefix from its temporary folder.
  SANDBOX_BOOK_DIR="$SANDBOX/tmp/bench-book-$$"
  mkdir -p "$SANDBOX_BOOK_DIR"
  cp "$BOOK" "$SANDBOX_BOOK_DIR/book.zip"
  export TEST_RUNNER_PANELY_BENCHMARK_BOOK="$SANDBOX_BOOK_DIR/book.zip"
  export TEST_RUNNER_PANELY_BENCHMARK_BOOK_PAGES="$BOOK_PAGES"
  export TEST_RUNNER_PANELY_BENCHMARK_BOOK_FIRST="$BOOK_FIRST"
  export TEST_RUNNER_PANELY_BENCHMARK_BOOK_SOURCE="${BOOK_PAIR%-*}"
  export TEST_RUNNER_PANELY_BENCHMARK_BOOK_TARGET="${BOOK_PAIR#*-}"
  ONLY_TESTING+=(-only-testing:PanelyTests/TranslationBenchmarkTests/realBook\(\))
fi

for ((run = 1; run <= RUNS; run++)); do
  echo "▶︎ Benchmark run $run/$RUNS ($LABEL)…"
  mkdir -p "$(dirname "$RESULTS")"
  : > "$RESULTS"
  xcodebuild test-without-building "${XCODEBUILD_ARGS[@]}" "${ONLY_TESTING[@]}" 2>&1 \
    | grep -E "error:|✘|Test run with|\*\* " | grep -v "com.apple.linkd" || true
  if [[ ! -s "$RESULTS" ]]; then
    echo "✗ No results in $RESULTS (did the benchmark run?)" >&2
    exit 1
  fi
  sed "s/^BENCH /BENCH run=$run /" "$RESULTS" | tee -a "${OUT:-/dev/null}"
done
