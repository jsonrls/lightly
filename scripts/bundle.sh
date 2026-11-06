#!/bin/bash
# Builds dist/Mac Cleaner.app, which only ever dry-runs. With --live the bundle
# really deletes files: only that flag writes MacCleanerLive into Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

app="dist/Mac Cleaner.app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/MacCleaner" "$app/Contents/MacOS/MacCleaner"
cp Resources/Info.plist "$app/Contents/Info.plist"  # replaces any earlier --live plist
if [ "${1:-}" = "--live" ]; then
  /usr/libexec/PlistBuddy -c "Add :MacCleanerLive bool true" "$app/Contents/Info.plist"
fi

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }' || true)"
fi
codesign --force --options runtime --sign "${IDENTITY:--}" "$app"
echo "Built $app, signed with ${IDENTITY:--}"
