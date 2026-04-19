#!/usr/bin/env bash
set -euo pipefail

# Generates Panely/AppIcon.icns from an SVG source.
#
# Usage:
#   scripts/generate-app-icon.sh [SVG_PATH] [ICNS_PATH]
#
# Defaults:
#   SVG_PATH  = docs/icon/panely-icon-stacked.svg
#   ICNS_PATH = Panely/AppIcon.icns

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SVG="${1:-$REPO_ROOT/docs/icon/panely-icon-stacked.svg}"
ICNS="${2:-$REPO_ROOT/Panely/AppIcon.icns}"

# --- dependency checks ---
missing=()
for cmd in rsvg-convert magick iconutil; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
    fi
done
if (( ${#missing[@]} > 0 )); then
    echo "error: missing required tools: ${missing[*]}" >&2
    echo "install via: brew install librsvg imagemagick" >&2
    exit 1
fi

if [[ ! -f "$SVG" ]]; then
    echo "error: SVG not found at $SVG" >&2
    exit 1
fi

SRGB_PROFILE="/System/Library/ColorSync/Profiles/sRGB Profile.icc"
if [[ ! -f "$SRGB_PROFILE" ]]; then
    echo "error: sRGB profile not found at $SRGB_PROFILE" >&2
    exit 1
fi

ICONSET="$(mktemp -d -t panely-iconset-XXXXXX)/AppIcon.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

echo "→ source:      $SVG"
echo "→ destination: $ICNS"
echo "→ iconset:     $ICONSET"
echo

# name:pixel pairs for every required slot in a macOS .icns
declare -a ENTRIES=(
    "icon_16x16.png:16"
    "icon_16x16@2x.png:32"
    "icon_32x32.png:32"
    "icon_32x32@2x.png:64"
    "icon_128x128.png:128"
    "icon_128x128@2x.png:256"
    "icon_256x256.png:256"
    "icon_256x256@2x.png:512"
    "icon_512x512.png:512"
    "icon_512x512@2x.png:1024"
)

echo "rasterizing SVG..."
for entry in "${ENTRIES[@]}"; do
    name="${entry%%:*}"
    size="${entry##*:}"
    rsvg-convert -w "$size" -h "$size" "$SVG" -o "$ICONSET/$name"
    printf '  %-26s %4dx%d\n' "$name" "$size" "$size"
done

echo
echo "embedding sRGB profile..."
for png in "$ICONSET"/*.png; do
    magick "$png" -colorspace sRGB -profile "$SRGB_PROFILE" "$png"
done

echo
echo "building icns..."
mkdir -p "$(dirname "$ICNS")"
iconutil -c icns "$ICONSET" -o "$ICNS"

bytes=$(stat -f%z "$ICNS")
echo
echo "✓ wrote $ICNS (${bytes} bytes)"
