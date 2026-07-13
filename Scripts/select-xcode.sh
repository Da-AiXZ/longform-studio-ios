#!/usr/bin/env bash
set -euo pipefail

XCODE_PATH="/Applications/Xcode_16.4.app"
if [[ ! -d "$XCODE_PATH" ]]; then
  echo "Required Xcode 16.4 is not installed on this runner." >&2
  ls -1 /Applications | grep '^Xcode' || true
  exit 1
fi

sudo xcode-select --switch "$XCODE_PATH/Contents/Developer"
ACTUAL_VERSION="$(xcodebuild -version | head -n 1)"
if [[ "$ACTUAL_VERSION" != "Xcode 16.4" ]]; then
  echo "Expected Xcode 16.4, got: $ACTUAL_VERSION" >&2
  exit 1
fi
xcodebuild -version
