#!/usr/bin/env bash
# Reusable manual capture entry point. See the capture guide in README.ko.md.
# Examples:
#   scripts/generate-snapshots.sh --list
#   scripts/generate-snapshots.sh --only balloon-add
#   scripts/generate-snapshots.sh --output build/manual-preview
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/manual-snapshots.py" "$@"
