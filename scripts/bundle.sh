#!/bin/bash
# Builds dist/Lightly.app, which only ever dry-runs. With --live the bundle
# really deletes files: only that flag writes MacCleanerLive into Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

app="dist/Lightly.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MacCleaner" "$app/Contents/MacOS/MacCleaner"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
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
