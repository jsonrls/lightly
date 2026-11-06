#!/bin/bash
# Builds dist/Mac Cleaner.app. Building only: a release build run without
# --dry-run-report or MACCLEANER_DRY_RUN=1 really deletes files.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

app="dist/Mac Cleaner.app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/MacCleaner" "$app/Contents/MacOS/MacCleaner"
cp Resources/Info.plist "$app/Contents/Info.plist"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }' || true)"
fi
codesign --force --options runtime --sign "${IDENTITY:--}" "$app"
echo "Built $app, signed with ${IDENTITY:--}"
