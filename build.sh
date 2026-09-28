#!/bin/bash
# Builds "Vibhor's Notch.app" into ./build
#   ./build.sh            build only
#   ./build.sh --run      build, then (re)launch
#   ./build.sh --install  build, copy to /Applications, then launch
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Vibhor's Notch"
EXEC="VibhorsNotch"
APP="build/$APP_NAME.app"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC" "$APP/Contents/MacOS/$EXEC"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"

case "${1:-}" in
  --run)
    pkill -x "$EXEC" 2>/dev/null || true
    open "$APP"
    ;;
  --install)
    pkill -x "$EXEC" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/"
    open "/Applications/$APP_NAME.app"
    echo "Installed to /Applications/$APP_NAME.app"
    ;;
esac
