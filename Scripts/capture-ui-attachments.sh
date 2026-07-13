#!/usr/bin/env bash
set -euo pipefail

RESULT_BUNDLE="${1:?Usage: capture-ui-attachments.sh <xcresult> <output-dir>}"
OUTPUT_DIR="${2:?Usage: capture-ui-attachments.sh <xcresult> <output-dir>}"
mkdir -p "$OUTPUT_DIR"
xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" --output-path "$OUTPUT_DIR" || true
