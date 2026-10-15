#!/usr/bin/env bash
#
# Time the translation pipeline: each stage on its own (page read, decode,
# balloon detection, OCR, the full analysis, translation and speech-level
# rewrites per balloon) and whole translation jobs, the way the app runs them.
#
# Runs PanelyTests/TranslationBenchmarkTests, which is off in every ordinary
# test run: it's enabled for this run's test process only, through
# TEST_RUNNER_-prefixed variables (xcodebuild passes them on to the tests
# with the prefix dropped).
#
# Needs Apple Translation's language packs for the pairs measured (ja→ko for
# the synthetic pages, the book's pair for --book; fast mode) and Apple
# Intelligence for speech levels. What couldn't run is reported as skipped.
#
# The test host is sandboxed, so a --book is copied into the sandbox's
# temporary folder for the run and deleted afterwards. The book itself is
# only read.
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
#   --parts LIST         any of stages, job, speechConcurrency (default
#                        stages,job; speechConcurrency times the model
#                        answering 1–4 rewrites at a time, after stages)
#   --no-speech-level    jobs don't match speech levels
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
SPEECH_LEVEL=1
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
    --no-speech-level) SPEECH_LEVEL=0; shift ;;
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
export TEST_RUNNER_PANELY_BENCHMARK_SPEECH_LEVEL="$SPEECH_LEVEL"
export TEST_RUNNER_PANELY_BENCHMARK_BOOK=""

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
