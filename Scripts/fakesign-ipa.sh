#!/usr/bin/env bash
set -euo pipefail

INPUT_IPA="${1:?Usage: fakesign-ipa.sh <input-ipa> <output-ipa>}"
OUTPUT_IPA="${2:?Usage: fakesign-ipa.sh <input-ipa> <output-ipa>}"
LDID_VERSION="v2.1.5-procursus7"
LDID_SHA256="5dff8e6b8d9dc3ff7226276c81e09930865f15381f54cb55b98b196a94c5ca50"
LDID_URL="https://github.com/ProcursusTeam/ldid/releases/download/${LDID_VERSION}/ldid_macosx_arm64"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

LDID_PATH="$WORK_DIR/ldid"
curl --fail --location --retry 3 --output "$LDID_PATH" "$LDID_URL"
echo "${LDID_SHA256}  ${LDID_PATH}" | shasum -a 256 --check
chmod +x "$LDID_PATH"

unzip -q "$INPUT_IPA" -d "$WORK_DIR/package"
APP_PATH="$(find "$WORK_DIR/package/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "No .app bundle found in IPA." >&2
  exit 1
fi

find "$APP_PATH" -type d -name '*.framework' -print0 | while IFS= read -r -d '' framework; do
  binary="$framework/$(basename "$framework" .framework)"
  if [[ -f "$binary" ]]; then "$LDID_PATH" -S "$binary"; fi
done

find "$APP_PATH" -type f -perm -111 ! -path '*/Frameworks/*.framework/*' -print0 | while IFS= read -r -d '' binary; do
  if file "$binary" | grep -q 'Mach-O'; then "$LDID_PATH" -S "$binary"; fi
done

rm -f "$OUTPUT_IPA"
(
  cd "$WORK_DIR/package"
  /usr/bin/zip -qry "$OUTPUT_IPA" Payload
)
