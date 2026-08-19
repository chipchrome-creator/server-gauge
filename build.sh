#!/bin/bash
# Build Server Gauge.app — a menu-bar-only app (no dock icon).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Server Gauge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ServerGauge "$APP/Contents/MacOS/ServerGauge"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built: $(pwd)/$APP"

# ./build.sh install → put it in /Applications and (re)launch it there.
if [[ "${1:-}" == "install" ]]; then
  pkill -f "Server Gauge.app/Contents/MacOS/ServerGauge" 2>/dev/null || true
  sleep 1 # let the old instance fully exit before replacing + relaunching
  # Remove first: ditto merges into an existing bundle, which can leave
  # stale files from older versions and break the code signature.
  rm -rf "/Applications/$APP"
  ditto "$APP" "/Applications/$APP"
  sleep 1
  open "/Applications/$APP"
  echo "Installed + launched: /Applications/$APP"
else
  echo "Run:   open \"$(pwd)/$APP\"   (or ./build.sh install)"
fi
