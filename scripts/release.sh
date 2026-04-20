#!/usr/bin/env bash
set -euo pipefail

# Cut a new Panely release.
#
# Usage:
#   scripts/release.sh                # interactive
#   scripts/release.sh 1.2.3          # explicit version
#   scripts/release.sh major          # bump major (e.g., 1.4.2 -> 2.0.0)
#   scripts/release.sh minor          # bump minor (e.g., 1.4.2 -> 1.5.0)
#   scripts/release.sh patch          # bump patch (e.g., 1.4.2 -> 1.4.3)
#
# Env flags:
#   SKIP_TESTS=1    skip local xcodebuild test
#   NO_PUSH=1       commit & tag locally but don't push
#
# What it does:
#   1. Pre-flight: git clean, on main, synced with origin, tag not taken.
#   2. Optionally run tests.
#   3. Bump MARKETING_VERSION in project.pbxproj.
#   4. Commit "chore: release vX.Y.Z" + annotated tag.
#   5. Push main + tag. GitHub Actions release.yml publishes the .zip.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PBXPROJ="$REPO_ROOT/Panely.xcodeproj/project.pbxproj"
MAIN_BRANCH="main"

cd "$REPO_ROOT"

# --- helpers ---
die() { echo "error: $*" >&2; exit 1; }

confirm() {
    local prompt="$1"
    read -r -p "$prompt [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

bump_semver() {
    local version="$1" part="$2"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$version"
    major=${major:-0}; minor=${minor:-0}; patch=${patch:-0}
    case "$part" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "$major.$((minor + 1)).0" ;;
        patch) echo "$major.$minor.$((patch + 1))" ;;
        *)     die "unknown semver part: $part" ;;
    esac
}

# --- read current version ---
[[ -f "$PBXPROJ" ]] || die "project.pbxproj not found: $PBXPROJ"

current_version=$(grep -m1 'MARKETING_VERSION = ' "$PBXPROJ" \
    | sed -E 's/.*= ([^;]+);.*/\1/' | xargs)
[[ -n "$current_version" ]] || die "could not read current MARKETING_VERSION"

echo "→ current version: $current_version"

# --- determine new version ---
arg="${1:-}"
case "$arg" in
    major|minor|patch)
        new_version=$(bump_semver "$current_version" "$arg")
        ;;
    "")
        read -r -p "new version (current $current_version): " new_version
        ;;
    *)
        new_version="$arg"
        ;;
esac

[[ "$new_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    || die "'$new_version' is not a valid X.Y or X.Y.Z version"

tag="v$new_version"
echo "→ new version:     $new_version"
echo "→ tag:             $tag"
echo

# --- pre-flight ---
git diff-index --quiet HEAD -- \
    || die "working tree not clean. commit or stash first."

branch=$(git rev-parse --abbrev-ref HEAD)
[[ "$branch" == "$MAIN_BRANCH" ]] \
    || die "must be on '$MAIN_BRANCH' (currently on '$branch')"

echo "→ fetching origin..."
git fetch origin "$MAIN_BRANCH" --quiet

local_sha=$(git rev-parse HEAD)
remote_sha=$(git rev-parse "origin/$MAIN_BRANCH")
[[ "$local_sha" == "$remote_sha" ]] \
    || die "local $MAIN_BRANCH not in sync with origin ($local_sha vs $remote_sha)"

if git rev-parse "$tag" >/dev/null 2>&1; then
    die "tag '$tag' already exists locally"
fi

if git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
    die "tag '$tag' already exists on origin"
fi

# --- tests ---
if [[ "${SKIP_TESTS:-0}" == "1" ]]; then
    echo "→ tests skipped (SKIP_TESTS=1)"
else
    test_log="$REPO_ROOT/build/release-test.log"
    mkdir -p "$(dirname "$test_log")"
    echo "→ running tests (set SKIP_TESTS=1 to skip)..."
    echo "  log: $test_log"

    # Pin the destination to the host arch — `platform=macOS` alone matches
    # both arm64 and x86_64 destinations on Apple Silicon and prints a
    # WARNING. Use uname for a stable single-destination spec.
    arch=$(uname -m)
    case "$arch" in
        arm64)  destination='platform=macOS,arch=arm64' ;;
        x86_64) destination='platform=macOS,arch=x86_64' ;;
        *)      destination='platform=macOS' ;;
    esac

    # Save the full log; suppress only the noisiest build-system chatter so
    # actual test failures stay visible. Don't grep for specific result
    # markers — that hides anything that doesn't match the assumed format
    # and was the cause of false-positive "tests failed" reports.
    set +e
    xcodebuild test \
        -project Panely.xcodeproj \
        -scheme Panely \
        -destination "$destination" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        2>&1 | tee "$test_log" \
             | grep -vE '^(builtin-|/Applications/Xcode|cd |export |    )' \
             | grep -vE '(SwiftCompile|SwiftDriver|SwiftMergeGeneratedHeaders|CodeSign|Touch |GenerateDSYM|CompileC |ProcessInfoPlist|RegisterExecutionPolicyException|CopySwiftLibs|CreateBuildDirectory)'
    test_exit=${PIPESTATUS[0]}
    set -e

    if [[ $test_exit -ne 0 ]]; then
        die "tests failed (xcodebuild exit $test_exit) — see $test_log"
    fi
    if ! grep -q '\*\* TEST SUCCEEDED \*\*' "$test_log"; then
        die "tests did not produce success marker — see $test_log"
    fi
    echo "✓ tests passed"
fi

# --- bump version ---
# Replace all MARKETING_VERSION lines. BSD sed (macOS) requires the -i '' form.
sed -i '' -E \
    "s/(MARKETING_VERSION = )[^;]+;/\1$new_version;/g" \
    "$PBXPROJ"

grep -q "MARKETING_VERSION = $new_version;" "$PBXPROJ" \
    || die "failed to update MARKETING_VERSION"

echo "✓ bumped MARKETING_VERSION to $new_version"

# Restore pbxproj if user aborts before committing — keeps the working tree
# clean even on Ctrl-C between bump and commit.
trap 'echo; echo "→ restoring $PBXPROJ"; git checkout -- "$PBXPROJ" 2>/dev/null || true' ERR INT

# --- show diff + confirm ---
echo
echo "→ pending change:"
git --no-pager diff --color=always -- "$PBXPROJ"
echo

if ! confirm "commit + tag $tag?"; then
    echo "aborted. reverting version bump..."
    git checkout -- "$PBXPROJ"
    exit 0
fi

# --- commit + tag ---
git add "$PBXPROJ"
git commit -m "chore: release $tag"
git tag -a "$tag" -m "Release $tag"
trap - ERR INT
echo "✓ committed and tagged $tag"

# --- push ---
if [[ "${NO_PUSH:-0}" == "1" ]]; then
    echo
    echo "NO_PUSH=1, stopping before push."
    echo "push manually when ready:"
    echo "  git push origin $MAIN_BRANCH"
    echo "  git push origin $tag"
    exit 0
fi

echo
confirm "push $MAIN_BRANCH and $tag to origin?" || {
    echo "skipped push. run manually when ready:"
    echo "  git push origin $MAIN_BRANCH"
    echo "  git push origin $tag"
    exit 0
}

git push origin "$MAIN_BRANCH"
git push origin "$tag"

remote_url=$(git config --get remote.origin.url \
    | sed -E 's#git@github.com:#https://github.com/#; s/\.git$//')

echo
echo "✓ pushed. GitHub Actions will build and publish $tag."
if [[ "$remote_url" =~ ^https://github.com/ ]]; then
    echo "  actions: $remote_url/actions"
    echo "  releases: $remote_url/releases"
fi
