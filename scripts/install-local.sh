#!/usr/bin/env bash
set -euo pipefail

# Build Panely from the working tree and install it locally for hands-on
# testing — the same Release build CI ships, ad-hoc signed.
#
# Usage:
#   scripts/install-local.sh              # Release → /Applications/Panely.app, then launch
#   scripts/install-local.sh --debug      # Debug → /Applications/Panely Debug.app
#   scripts/install-local.sh --test       # run the test suite first
#   scripts/install-local.sh --dest ~/Applications --no-open --reveal
#
# Options:
#   --debug      Debug configuration. Its bundle id (io.github.sejoung.Panely.debug)
#                keeps its own settings, caches and sandbox container, so it can
#                sit next to a released Panely without touching its state.
#   --test       run `xcodebuild test` before building.
#   --dest DIR   install directory (default: /Applications, or ~/Applications
#                when /Applications isn't writable for this account).
#   --no-open    don't launch after installing.
#   --reveal     show the installed app in Finder.
#
# Notes:
#   - The Release build shares its bundle id — and therefore settings, reading
#     positions and caches — with an official Panely install, and installs to
#     the same /Applications/Panely.app, replacing it (reinstall the official
#     build from GitHub Releases afterwards). Use --debug to experiment without
#     affecting either.
#   - A running copy of the same app is quit before it's replaced.
#   - Built locally, the app carries no quarantine flag, so Gatekeeper opens it
#     without the "unidentified developer" prompt.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DERIVED_DATA="$REPO_ROOT/build/LocalInstallDerivedData"
LOG_DIR="$REPO_ROOT/build"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

configuration="Release"
installed_name="Panely.app"
dest_dir=""
run_tests=0
open_after=1
reveal=0

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)   configuration="Debug"; installed_name="Panely Debug.app" ;;
        --test)    run_tests=1 ;;
        --dest)    [[ $# -ge 2 ]] || die "--dest needs a directory"; dest_dir="$2"; shift ;;
        --no-open) open_after=0 ;;
        --reveal)  reveal=1 ;;
        # Print the header comment (everything after the shebang/set line up
        # to the first line of code).
        -h|--help) awk 'NR >= 4 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)         die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode"
cd "$REPO_ROOT"
mkdir -p "$LOG_DIR"

# Pin the destination to the host arch — `platform=macOS` alone matches both
# arm64 and x86_64 destinations on Apple Silicon and prints a WARNING.
case "$(uname -m)" in
    arm64)  destination='platform=macOS,arch=arm64' ;;
    x86_64) destination='platform=macOS,arch=x86_64' ;;
    *)      destination='platform=macOS' ;;
esac

# --- tests ---
if [[ $run_tests -eq 1 ]]; then
    test_log="$LOG_DIR/install-local-test.log"
    echo "→ running tests (log: $test_log)..."
    set +e
    xcodebuild test \
        -project Panely.xcodeproj \
        -scheme Panely \
        -destination "$destination" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGN_IDENTITY="-" \
        > "$test_log" 2>&1
    test_exit=$?
    set -e
    grep -E '^(✔|✘) Test run with' "$test_log" || true
    [[ $test_exit -eq 0 ]] && grep -q '\*\* TEST SUCCEEDED \*\*' "$test_log" \
        || die "tests failed (xcodebuild exit $test_exit) — see $test_log"
    echo "✓ tests passed"
fi

# --- build ---
build_log="$LOG_DIR/install-local-build.log"
echo "→ building $configuration (log: $build_log)..."
set +e
xcodebuild build \
    -project Panely.xcodeproj \
    -scheme Panely \
    -configuration "$configuration" \
    -destination "$destination" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    > "$build_log" 2>&1
build_exit=$?
set -e
if [[ $build_exit -ne 0 ]]; then
    grep -E 'error:' "$build_log" | sort -u | head -20 >&2 || true
    die "build failed (xcodebuild exit $build_exit) — see $build_log"
fi

built_app="$DERIVED_DATA/Build/Products/$configuration/Panely.app"
[[ -d "$built_app" ]] || die "build output not found at $built_app"
bundle_id=$(defaults read "$built_app/Contents/Info" CFBundleIdentifier)
version=$(defaults read "$built_app/Contents/Info" CFBundleShortVersionString)
build_number=$(defaults read "$built_app/Contents/Info" CFBundleVersion)
echo "✓ built $bundle_id $version ($build_number)"

# --- quit a running copy ---
if osascript -e "application id \"$bundle_id\" is running" 2>/dev/null | grep -q true; then
    echo "→ quitting the running $bundle_id..."
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
        osascript -e "application id \"$bundle_id\" is running" 2>/dev/null | grep -q true || break
        sleep 0.2
    done
    osascript -e "application id \"$bundle_id\" is running" 2>/dev/null | grep -q true \
        && die "$bundle_id is still running — quit it and try again"
fi

# --- install ---
# /Applications is where Finder's Applications sidebar item and Launchpad
# look. Admin accounts can write it without sudo; others fall back to the
# per-user ~/Applications (which Finder doesn't show in the sidebar).
if [[ -z "$dest_dir" ]]; then
    if [[ -w /Applications ]]; then
        dest_dir="/Applications"
    else
        dest_dir="$HOME/Applications"
        echo "→ /Applications isn't writable for $(id -un); installing to $dest_dir instead"
    fi
fi
mkdir -p "$dest_dir"
installed_app="$dest_dir/$installed_name"
if [[ -d "$installed_app" ]]; then
    previous=$(defaults read "$installed_app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    echo "→ replacing the existing $installed_name (version $previous)"
fi
echo "→ installing to $installed_app..."
rm -rf "$installed_app"
# ditto keeps the code signature, extended attributes and symlinks intact.
ditto "$built_app" "$installed_app"
codesign --verify --deep --strict "$installed_app" \
    || die "installed app failed signature verification"
# Point Launch Services (Open With, file associations) at this copy.
"$LSREGISTER" -f "$installed_app" >/dev/null 2>&1 || true
echo "✓ installed $installed_name ($version, $configuration)"
echo "  path: $installed_app"

if [[ $reveal -eq 1 ]]; then
    open -R "$installed_app"
fi

if [[ $open_after -eq 1 ]]; then
    open "$installed_app"
    echo "✓ launched"
fi

cat <<EOF

Try the experimental translation assist (macOS 26+):
  Settings (⌘,) → Experimental → Translation Assist
  open a book → ⌥⌘T translate this book, ⇧⌘T show/hide translation,
  click a balloon for the original + translation.
EOF
