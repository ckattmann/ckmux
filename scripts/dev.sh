#!/usr/bin/env bash
# Build, run, stop or talk to the local debug build.
#   scripts/dev.sh build        incremental Debug build
#   scripts/dev.sh run          build, then launch "cmux DEV.app" (tag: ckmux)
#   scripts/dev.sh stop         quit the running debug app
#   scripts/dev.sh cli ...      run the bundled cmux CLI against the debug app's socket
#   scripts/dev.sh clean        remove the derived data folder
#   scripts/dev.sh release      build Release, install /Applications/ckmux.app and ~/.local/bin/ckmux
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${CMUX_TAG:-ckmux}"
DERIVED="${CMUX_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/ckmux}"
APP="$DERIVED/Build/Products/Debug/cmux DEV.app"
SOCKET="/tmp/cmux-debug-$TAG.sock"

RELEASE_APP="$DERIVED/Build/Products/Release/ckmux.app"
INSTALLED_APP="/Applications/ckmux.app"
RELEASE_SOCKET="/tmp/cmux-debug-ckmux-app.sock"
CLI_SHIM="$HOME/.local/bin/ckmux"

build() {
  build_configuration Debug "$@"
}

build_configuration() {
  local configuration="$1"
  shift
  "$ROOT/scripts/ensure-ghosttykit.sh" >/dev/null
  xcodebuild \
    -project "$ROOT/cmux.xcodeproj" \
    -scheme cmux \
    -configuration "$configuration" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CMUX_GHOSTTYKIT_PREPROVISIONED=1 \
    CMUX_SKIP_ZIG_BUILD=1 \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
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

release() {
  local output
  output="$(build_configuration Release)"
  echo "$output"
  grep -q 'BUILD SUCCEEDED' <<<"$output" || exit 1
  codesign --force --deep --sign - "$RELEASE_APP"
  if pgrep -f "$INSTALLED_APP/Contents/MacOS/ckmux" >/dev/null; then
    osascript -e 'tell application id "com.chka.ckmux" to quit' || true
    sleep 2
  fi
  rm -rf "$INSTALLED_APP"
  ditto "$RELEASE_APP" "$INSTALLED_APP"
  mkdir -p "$(dirname "$CLI_SHIM")"
  cat >"$CLI_SHIM" <<SHIM
#!/usr/bin/env bash
exec "$INSTALLED_APP/Contents/Resources/bin/cmux" --socket "$RELEASE_SOCKET" "\$@"
SHIM
  chmod +x "$CLI_SHIM"
  echo "installed $INSTALLED_APP and $CLI_SHIM"
}

case "${1:-build}" in
  build) shift; build "$@" ;;
  run) run ;;
  stop) stop ;;
  cli) shift; exec "$APP/Contents/Resources/bin/cmux" --socket "$SOCKET" "$@" ;;
  clean) rm -rf "$DERIVED"; echo "removed $DERIVED" ;;
  release) release ;;
  *) echo "usage: $0 {build|run|stop|cli ...|clean|release}" >&2; exit 2 ;;
esac
