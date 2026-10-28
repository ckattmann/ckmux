#!/usr/bin/env bash
# Build, run, stop or talk to the local debug build.
#   scripts/dev.sh build        incremental Debug build
#   scripts/dev.sh run          build, then launch "cmux DEV.app" (tag: ckmux)
#   scripts/dev.sh stop         quit the running debug app
#   scripts/dev.sh cli ...      run the bundled cmux CLI against the debug app's socket
#   scripts/dev.sh clean        remove the derived data folder
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${CMUX_TAG:-ckmux}"
DERIVED="${CMUX_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/ckmux}"
APP="$DERIVED/Build/Products/Debug/cmux DEV.app"
SOCKET="/tmp/cmux-debug-$TAG.sock"

build() {
  "$ROOT/scripts/ensure-ghosttykit.sh" >/dev/null
  xcodebuild \
    -project "$ROOT/cmux.xcodeproj" \
    -scheme cmux \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CMUX_GHOSTTYKIT_PREPROVISIONED=1 \
    CMUX_SKIP_ZIG_BUILD=1 \
    build "$@" \
    | grep -E 'error:|warning: unre|BUILD (SUCCEEDED|FAILED)|\*\* ' || true
}

stop() {
  pkill -f "$APP/Contents/MacOS/cmux DEV" 2>/dev/null || true
}

run() {
  build
  stop
  sleep 0.5
  CMUX_TAG="$TAG" open -n "$APP"
  echo "launched $APP (socket: $SOCKET)"
}

case "${1:-build}" in
  build) shift; build "$@" ;;
  run) run ;;
  stop) stop ;;
  cli) shift; exec "$APP/Contents/Resources/bin/cmux" --socket "$SOCKET" "$@" ;;
  clean) rm -rf "$DERIVED"; echo "removed $DERIVED" ;;
  *) echo "usage: $0 {build|run|stop|cli ...|clean}" >&2; exit 2 ;;
esac
