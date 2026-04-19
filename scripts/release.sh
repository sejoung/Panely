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
    echo "→ running tests (set SKIP_TESTS=1 to skip)..."
    xcodebuild test \
        -project Panely.xcodeproj \
        -scheme Panely \
        -destination 'platform=macOS' \
        -skip-testing:PanelyUITests \
        CODE_SIGN_IDENTITY="-" \
        -quiet
    echo "✓ tests passed"
fi

# --- confirm ---
echo
confirm "release $tag?" || { echo "aborted."; exit 0; }

# --- bump version ---
# Replace all MARKETING_VERSION lines. BSD sed (macOS) requires the -i '' form.
sed -i '' -E \
    "s/(MARKETING_VERSION = )[^;]+;/\1$new_version;/g" \
    "$PBXPROJ"

grep -q "MARKETING_VERSION = $new_version;" "$PBXPROJ" \
    || die "failed to update MARKETING_VERSION"

echo "✓ bumped MARKETING_VERSION to $new_version"

# --- commit + tag ---
git add "$PBXPROJ"
git commit -m "chore: release $tag"
git tag -a "$tag" -m "Release $tag"
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
