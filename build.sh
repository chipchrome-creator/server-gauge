#!/bin/bash
# Build Server Gauge.app — a menu-bar-only app (no dock icon).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Server Gauge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ServerGauge "$APP/Contents/MacOS/ServerGauge"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built: $(pwd)/$APP"
echo "Run:   open \"$(pwd)/$APP\""
