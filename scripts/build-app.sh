#!/bin/bash
# Build Summonbar.app. Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/Summonbar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Summonbar "$APP/Contents/MacOS/Summonbar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Summonbar 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/Summonbar.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/Summonbar.app
  echo "Installed ~/Applications/Summonbar.app"
fi
