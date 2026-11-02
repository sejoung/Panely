#!/usr/bin/env bash
# Run real manga-ocr / PP-OCRv5 inference, downloading the pinned ~160 MB
# OCR pack once into the test host's cache. No Gemma download is needed.
# PANELY_OCR_LINE_DEVICE=coreml scripts/test-ocr.sh compares Core ML line detection.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TEST_RUNNER_PANELY_TEST_COMIC_OCR=1
export TEST_RUNNER_PANELY_COMPARE_VISION="${PANELY_COMPARE_VISION:-0}"
export TEST_RUNNER_PANELY_OCR_LINE_DEVICE="${PANELY_OCR_LINE_DEVICE:-cpu}"
exec "$SCRIPT_DIR/test.sh" --only ComicOCRIntegrationTests "$@"
