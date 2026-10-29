#!/usr/bin/env bash
# Makes GhosttyKit.xcframework resolve to the pinned prebuilt build (no Zig toolchain needed).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

GHOSTTY_SHA="${GHOSTTY_SHA:-ef4f1570d62117ebc51e3b0f07ad4f34032267b6}"
FLAVOR="crashsubdir-cmux-crash-sentry-off-noi18n-v2"
KEY="$GHOSTTY_SHA-$FLAVOR"
CACHE_DIR="${CMUX_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/cmux/ghosttykit}/$KEY"
LINK="$PROJECT_DIR/GhosttyKit.xcframework"

if [[ -f "$LINK/Info.plist" ]]; then
  exit 0
fi

if [[ ! -f "$CACHE_DIR/GhosttyKit.xcframework/Info.plist" ]]; then
  echo "==> Downloading prebuilt GhosttyKit ($KEY)"
  GHOSTTY_SHA="$GHOSTTY_SHA" \
  GHOSTTYKIT_BUILD_FLAVOR="$FLAVOR" \
  GHOSTTYKIT_OUTPUT_DIR="$CACHE_DIR/GhosttyKit.xcframework" \
    "$SCRIPT_DIR/download-prebuilt-ghosttykit.sh"
fi

rm -rf "$LINK"
ln -s "$CACHE_DIR/GhosttyKit.xcframework" "$LINK"
echo "==> GhosttyKit.xcframework -> $CACHE_DIR/GhosttyKit.xcframework"
