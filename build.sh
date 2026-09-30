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
# Sign with the stable local identity (scripts/setup-signing.sh) so macOS keeps the app's
# Accessibility/Microphone permissions across rebuilds; fall back to ad-hoc signing.
IDENTITY="Vibhor Notch Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  if ! SIGN_OUT="$(codesign --force --sign "$IDENTITY" "$APP" 2>&1)"; then
    echo "error: code signing failed (is the login keychain locked?):" >&2
    echo "$SIGN_OUT" >&2
    exit 1
  fi
else
  echo "warning: no '$IDENTITY' identity; run scripts/setup-signing.sh so permissions survive rebuilds"
  codesign --force --sign - "$APP" >/dev/null
fi

echo "Built $APP"

case "${1:-}" in
  --run)
    pkill -x "$EXEC" 2>/dev/null || true
    open "$APP"
    ;;
  --install)
    pkill -x "$EXEC" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    # Move rather than copy so there's only ever one copy of the app to launch.
    mv "$APP" "/Applications/"
    open "/Applications/$APP_NAME.app"
    echo "Installed to /Applications/$APP_NAME.app"
    ;;
esac
