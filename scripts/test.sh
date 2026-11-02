#!/usr/bin/env bash
# Shared test runner for local work, CI and the opt-in tier wrappers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

usage() {
  cat <<'EOF'
Usage: scripts/test.sh [options] [xcodebuild arguments...]

  --only TEST          Run a suite or test; repeat to select several.
                       Example: --only TranslationControllerTests
  --repeat N           Run N separate test processes (1–100), stop on failure.
                       Builds on the first run, reuses that build afterwards.
  --skip-build         Reuse an existing build on every run.
  --clean              Clean before the first build.
  --configuration NAME Debug (default) or Release.
  --derived-data PATH  Build cache (or PANELY_DERIVED_DATA_PATH).
  --results-dir PATH   Results parent (default: build/test-results).
  -h, --help           Show this help.

Each invocation creates a new results directory with the full log, exact
command and .xcresult for every run. The original xcodebuild exit code is
preserved. Legacy -only-testing:... and build settings are also accepted.

Examples:
  scripts/test.sh
  scripts/test.sh --only TranslationControllerTests --repeat 5
  scripts/test.sh --skip-build --only DebouncerTests
  scripts/test-ocr.sh --repeat 3 SWIFT_OPTIMIZATION_LEVEL=-O
EOF
}

die() { echo "error: $*" >&2; exit 2; }
need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"; }

repeat=1
skip_build=0
clean=0
configuration=Debug
derived_data="${PANELY_DERIVED_DATA_PATH:-/private/tmp/PanelyDerivedData}"
results_parent="$PROJECT_ROOT/build/test-results"
extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      need_value "$@"
      selection="$2"
      [[ "$selection" == PanelyTests/* ]] || selection="PanelyTests/$selection"
      extra+=("-only-testing:$selection")
      shift 2 ;;
    --repeat) need_value "$@"; repeat="$2"; shift 2 ;;
    --skip-build) skip_build=1; shift ;;
    --clean) clean=1; shift ;;
    --configuration) need_value "$@"; configuration="$2"; shift 2 ;;
    --derived-data) need_value "$@"; derived_data="$2"; shift 2 ;;
    --results-dir) need_value "$@"; results_parent="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; extra+=("$@"); break ;;
    -test-iterations|-retry-tests-on-failure|-run-tests-until-failure)
      die "use --repeat N for reliable Swift Testing repetitions" ;;
    --*) die "unknown option: $1 (see --help)" ;;
    *) extra+=("$1"); shift ;;
  esac
done

[[ "$repeat" =~ ^[1-9][0-9]*$ && ${#repeat} -le 3 ]] || die "--repeat must be an integer from 1 to 100"
[[ "$repeat" -le 100 ]] || die "--repeat must be an integer from 1 to 100"
[[ "$configuration" == Debug || "$configuration" == Release ]] || die "--configuration must be Debug or Release"
[[ $clean -eq 0 || $skip_build -eq 0 ]] || die "--clean and --skip-build cannot be combined"
command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode"

mkdir -p "$results_parent"
results_parent="$(cd "$results_parent" && pwd)"
results="$results_parent/$(date +%Y%m%d-%H%M%S)-$$"
mkdir "$results"
case "$(uname -m)" in
  arm64|x86_64) destination="platform=macOS,arch=$(uname -m)" ;;
  *) destination='platform=macOS' ;;
esac

for ((run = 1; run <= repeat; run++)); do
  action=(test)
  if [[ $skip_build -eq 1 || $run -gt 1 ]]; then
    action=(test-without-building)
  elif [[ $clean -eq 1 ]]; then
    action=(clean test)
  fi
  log="$results/run-$run.log"
  bundle="$results/run-$run.xcresult"
  command=(xcodebuild "${action[@]}"
    -project Panely.xcodeproj -scheme Panely -configuration "$configuration"
    -destination "$destination" -derivedDataPath "$derived_data"
    -resultBundlePath "$bundle" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES
  )
  command+=(${extra[@]+"${extra[@]}"})
  printf '%q ' "${command[@]}" > "$results/run-$run.command"
  printf '\n' >> "$results/run-$run.command"
  echo "→ $configuration tests ($run/$repeat)"

  # Preserve xcodebuild's status even when the console filter matches nothing.
  set +e
  "${command[@]}" 2>&1 | tee "$log" | awk '
    /com\.apple\.linkd\.autoShortcut/ { next }
    /error:|✘ |Test run with|^\*\* |OCRBENCH|GEMMA|differs from|Rendered:|Diff:|📸/ { print; fflush() }
  '
  status=("${PIPESTATUS[@]}")
  set -e
  exit_code="${status[0]}"
  if [[ $exit_code -eq 0 ]]; then
    for pipeline_status in "${status[@]}"; do
      if [[ $pipeline_status -ne 0 ]]; then exit_code="$pipeline_status"; break; fi
    done
  fi
  if [[ $exit_code -ne 0 ]]; then
    echo "✗ Run $run failed (exit $exit_code). Full log: $log" >&2
    echo "  Result bundle: $bundle" >&2
    exit "$exit_code"
  fi
done

echo "✓ $repeat test run(s) passed. Results: $results"
