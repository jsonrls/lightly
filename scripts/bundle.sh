#!/bin/bash
# Builds dist/Lightly.app, which only ever dry-runs. With --live the bundle
# really deletes files: only that flag compiles MACCLEANER_LIVE into the binary,
# where an edit after signing breaks the code, unlike a key in Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

# Separate build folders, so a dry-run build can never reuse objects compiled live.
build=(-c release --scratch-path .build/dry)
if [ "${1:-}" = "--live" ]; then build=(-c release --scratch-path .build/live -Xswiftc -DMACCLEANER_LIVE); fi
swift build "${build[@]}"

app="dist/Lightly.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build "${build[@]}" --show-bin-path)/MacCleaner" "$app/Contents/MacOS/MacCleaner"
cp Resources/AppIcon.icns Resources/MenuBarIcon.svg "$app/Contents/Resources/"
cp Resources/Info.plist "$app/Contents/Info.plist"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }' || true)"
fi
codesign --force --options runtime --sign "${IDENTITY:--}" "$app"
echo "Built $app, signed with ${IDENTITY:--}"
