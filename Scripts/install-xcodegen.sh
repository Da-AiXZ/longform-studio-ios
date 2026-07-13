#!/usr/bin/env bash
set -euo pipefail

VERSION="2.41.0"
ARCHIVE="${RUNNER_TEMP:-/tmp}/xcodegen-${VERSION}.zip"
DESTINATION="${RUNNER_TEMP:-/tmp}/xcodegen-${VERSION}"
EXPECTED_SHA256="2ba336bcd1cb6ac224539140ed063e5d471e3400dd22ea1448f3734b0fa3cb3a"
URL="https://github.com/yonaskolb/XcodeGen/releases/download/${VERSION}/xcodegen.zip"

curl --fail --location --retry 3 --output "$ARCHIVE" "$URL"
echo "${EXPECTED_SHA256}  ${ARCHIVE}" | shasum -a 256 --check
rm -rf "$DESTINATION"
mkdir -p "$DESTINATION"
unzip -q "$ARCHIVE" -d "$DESTINATION"
echo "${DESTINATION}/xcodegen/bin" >> "$GITHUB_PATH"
"${DESTINATION}/xcodegen/bin/xcodegen" --version
