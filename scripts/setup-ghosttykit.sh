#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SOURCE_DIR="${GHOSTTY_SOURCE_DIR:-}"
if [[ -z "$SOURCE_DIR" ]]; then
  if [[ -d "$PROJECT_DIR/../cloned/ghostty" ]]; then
    SOURCE_DIR="$PROJECT_DIR/../cloned/ghostty"
  elif [[ -d "$PROJECT_DIR/vendor/ghostty" ]]; then
    SOURCE_DIR="$PROJECT_DIR/vendor/ghostty"
  fi
fi

if [[ -z "$SOURCE_DIR" || ! -d "$SOURCE_DIR" ]]; then
  echo "error: Ghostty source checkout not found."
  echo "Set GHOSTTY_SOURCE_DIR or place a checkout at ../cloned/ghostty or vendor/ghostty."
  exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "error: zig is required to build GhosttyKit."
  echo "Install zig, then rerun this script."
  exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: full Xcode is required to build GhosttyKit."
  echo "Run: sudo xcode-select --switch /Applications/Xcode.app"
  exit 1
fi

if ! xcrun -sdk macosx metal -v >/dev/null 2>&1; then
  echo "error: the Apple Metal compiler is not available to Xcode."
  echo "Run: ./scripts/fix-metal-toolchain.sh"
  exit 1
fi

echo "==> Building GhosttyKit from: $SOURCE_DIR"
(
  cd "$SOURCE_DIR"
  zig build \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target=native \
    -Doptimize=ReleaseFast
)

XCFRAMEWORK_PATH="$SOURCE_DIR/macos/GhosttyKit.xcframework"
if [[ ! -d "$XCFRAMEWORK_PATH" ]]; then
  echo "error: GhosttyKit.xcframework was not produced at $XCFRAMEWORK_PATH"
  exit 1
fi

ln -sfn "$XCFRAMEWORK_PATH" "$PROJECT_DIR/GhosttyKit.xcframework"
echo "==> Linked $PROJECT_DIR/GhosttyKit.xcframework"
echo "==> Next: xcrun swift run codeboard"
