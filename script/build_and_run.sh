#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PortviewHost"
BUNDLE_ID="dev.finklea.portview.host"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_PROJECT="$ROOT_DIR/apps/PortviewHost/PortviewHost.xcodeproj"
DERIVED_DATA="$ROOT_DIR/build/local-derived-data"
BUILT_APP="$DERIVED_DATA/Build/Products/Debug/PortviewHost.app"
INSTALLED_APP="/Applications/PortviewHost.app"
APP_BINARY="$INSTALLED_APP/Contents/MacOS/$APP_NAME"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "error: full Xcode developer directory not found at $DEVELOPER_DIR" >&2
  exit 1
fi

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

make -C "$ROOT_DIR" generate
xcodebuild build \
  -project "$HOST_PROJECT" \
  -scheme PortviewHost \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER=

if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: built app not found at $BUILT_APP" >&2
  exit 1
fi

rm -rf "$INSTALLED_APP"
/usr/bin/ditto "$BUILT_APP" "$INSTALLED_APP"

open_app() {
  /usr/bin/open -n "$INSTALLED_APP"
}

verify_process() {
  for _ in {1..20}; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  echo "error: $APP_NAME did not stay running after launch" >&2
  return 1
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
    verify_process
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    verify_process
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"dev.finklea.portview\""
    ;;
  --verify|verify)
    open_app
    verify_process
    ;;
esac
