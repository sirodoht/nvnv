#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="nvnv"
BUNDLE_ID="com.zfrankel.nvnv"
CONFIGURATION="${NVNV_BUILD_CONFIGURATION:-Release}"

if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
  CONFIGURATION="Debug"
fi

case "$CONFIGURATION" in
  debug) CONFIGURATION="Debug" ;;
  release) CONFIGURATION="Release" ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
PROJECT="$ROOT_DIR/nvnv.xcodeproj"
DERIVED_DATA="$ROOT_DIR/.build/xcode-derived"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

rm -rf "$APP_BUNDLE"
mkdir -p "$DIST_DIR"
cp -R "$BUILT_APP" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
