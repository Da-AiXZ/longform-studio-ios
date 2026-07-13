#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?Usage: package-ipa.sh <app-path> <output-ipa>}"
OUTPUT_IPA="${2:?Usage: package-ipa.sh <app-path> <output-ipa>}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/Payload"
ditto "$APP_PATH" "$WORK_DIR/Payload/$(basename "$APP_PATH")"
(
  cd "$WORK_DIR"
  /usr/bin/zip -qry "$OUTPUT_IPA" Payload
)
