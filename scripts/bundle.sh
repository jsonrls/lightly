#!/bin/bash
# Builds dist/Lightly.app, which only ever dry-runs. With --live the bundle
# really deletes files: only that flag compiles MACCLEANER_LIVE into the binary,
# where an edit after signing breaks the code, unlike a key in Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

flags=()
if [ "${1:-}" = "--live" ]; then flags=(-Xswiftc -DMACCLEANER_LIVE); fi
swift build -c release ${flags[@]+"${flags[@]}"}  # macOS bash 3.2 calls an empty array unbound

app="dist/Lightly.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MacCleaner" "$app/Contents/MacOS/MacCleaner"
cp Resources/AppIcon.icns Resources/MenuBarIcon.svg "$app/Contents/Resources/"
cp Resources/Info.plist "$app/Contents/Info.plist"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }' || true)"
fi
codesign --force --options runtime --sign "${IDENTITY:--}" "$app"
echo "Built $app, signed with ${IDENTITY:--}"
