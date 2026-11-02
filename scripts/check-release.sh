#!/usr/bin/env bash
# Build and verify the same universal, optimized app used for releases.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

derived_data="${PANELY_DERIVED_DATA_PATH:-$PROJECT_ROOT/build/DerivedData}"
results_parent="$PROJECT_ROOT/build/release-checks"
die() { echo "error: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --derived-data|--results-dir)
      [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a directory"
      if [[ "$1" == --derived-data ]]; then derived_data="$2"; else results_parent="$2"; fi
      shift 2 ;;
    -h|--help)
      echo 'Usage: scripts/check-release.sh [--derived-data PATH] [--results-dir PATH]'
      echo 'Builds Release for arm64 and x86_64, verifies architectures and signature, and saves build diagnostics.'
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

mkdir -p "$results_parent"
results_parent="$(cd "$results_parent" && pwd)"
results="$results_parent/$(date +%Y%m%d-%H%M%S)-$$"
mkdir "$results"
xcodebuild -version > "$results/toolchain.log"
command=(xcodebuild build
  -project Panely.xcodeproj -scheme Panely -configuration Release
  -destination 'generic/platform=macOS' -derivedDataPath "$derived_data"
  -resultBundlePath "$results/build.xcresult"
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES
)
printf '%q ' "${command[@]}" > "$results/build.command"
printf '\n' >> "$results/build.command"
echo '→ Universal Release build (arm64 + x86_64)'
set +e
"${command[@]}" 2>&1 | tee "$results/build.log" | awk '
  /error:|Please submit a bug report|Stack dump:|While running pass|\*\* BUILD/ { print; fflush() }
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
  echo "✗ Release build failed (exit $exit_code). Diagnostics: $results" >&2
  exit "$exit_code"
fi

app="$derived_data/Build/Products/Release/Panely.app"
for arch in arm64 x86_64; do
  lipo "$app/Contents/MacOS/Panely" -verify_arch "$arch" \
    || die "Release executable is missing a required architecture ($arch): $app"
done
codesign --verify --deep --strict "$app" \
  || die "Release signature verification failed: $app"
echo "✓ Universal Release verified. Diagnostics: $results"
