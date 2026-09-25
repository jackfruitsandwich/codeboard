#!/usr/bin/env bash
# Builds GhosttyKit.xcframework from a pinned Ghostty commit and links it into
# the repo. Codeboard uses Ghostty's embedding API, which upstream changes
# without notice, so only the pinned commit is known to build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GHOSTTY_REPO="${GHOSTTY_REPO:-https://github.com/ghostty-org/ghostty.git}"
GHOSTTY_COMMIT="${GHOSTTY_COMMIT:-ba398dfff3e30ff83da07140981ca138410cf608}"
REQUIRED_ZIG="0.15"

SOURCE_DIR="${GHOSTTY_SOURCE_DIR:-}"
if [[ -z "$SOURCE_DIR" ]]; then
  if [[ -d "$PROJECT_DIR/vendor/ghostty" ]]; then
    SOURCE_DIR="$PROJECT_DIR/vendor/ghostty"
  elif [[ -d "$PROJECT_DIR/../cloned/ghostty" ]]; then
    SOURCE_DIR="$PROJECT_DIR/../cloned/ghostty"
  else
    SOURCE_DIR="$PROJECT_DIR/vendor/ghostty"
    echo "==> Cloning Ghostty into $SOURCE_DIR"
    git clone --filter=blob:none "$GHOSTTY_REPO" "$SOURCE_DIR"
  fi
fi

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  echo "error: $SOURCE_DIR is not a Ghostty git checkout."
  echo "Set GHOSTTY_SOURCE_DIR to one, or remove it so this script clones Ghostty into vendor/ghostty."
  exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "error: zig $REQUIRED_ZIG.x is required to build GhosttyKit (brew install zig)."
  exit 1
fi
ZIG_VERSION="$(zig version)"
if [[ "$ZIG_VERSION" != "$REQUIRED_ZIG".* ]]; then
  echo "error: zig $REQUIRED_ZIG.x is required, found $ZIG_VERSION."
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

CURRENT_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [[ "$CURRENT_COMMIT" != "$GHOSTTY_COMMIT" ]]; then
  if [[ -n "$(git -C "$SOURCE_DIR" status --porcelain)" ]]; then
    echo "error: $SOURCE_DIR is at $CURRENT_COMMIT with local changes; Codeboard needs $GHOSTTY_COMMIT."
    echo "Commit or stash them, or set GHOSTTY_COMMIT to build against that checkout as-is."
    exit 1
  fi
  echo "==> Checking out Ghostty $GHOSTTY_COMMIT"
  git -C "$SOURCE_DIR" cat-file -e "$GHOSTTY_COMMIT^{commit}" 2>/dev/null \
    || git -C "$SOURCE_DIR" fetch origin "$GHOSTTY_COMMIT"
  git -C "$SOURCE_DIR" checkout --detach "$GHOSTTY_COMMIT"
fi

XCFRAMEWORK_PATH="$SOURCE_DIR/macos/GhosttyKit.xcframework"
# Remove the previous output so a leftover copy cannot pass the check below.
rm -rf "$XCFRAMEWORK_PATH"

echo "==> Building GhosttyKit from: $SOURCE_DIR ($GHOSTTY_COMMIT)"
BUILD_OK=1
(
  cd "$SOURCE_DIR"
  zig build \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target=native \
    -Doptimize=ReleaseFast
) || BUILD_OK=0

# Codeboard only needs the xcframework. Ghostty's build also installs the
# unrelated libghostty-vt.dylib, whose bundled libc++ does not compile with
# zig 0.15.2 against the macOS 27 SDK. The xcframework is still installed in
# that case, so accept the run when it is there.
if [[ ! -f "$XCFRAMEWORK_PATH/macos-arm64/libghostty-fat.a" && ! -f "$XCFRAMEWORK_PATH/macos-arm64_x86_64/libghostty-fat.a" ]]; then
  echo "error: GhosttyKit.xcframework was not produced at $XCFRAMEWORK_PATH"
  exit 1
fi
if [[ $BUILD_OK -eq 0 ]]; then
  echo "warning: zig build reported a failure (libghostty-vt), but GhosttyKit.xcframework was built; continuing."
fi

ln -sfn "$XCFRAMEWORK_PATH" "$PROJECT_DIR/GhosttyKit.xcframework"
echo "==> Linked $PROJECT_DIR/GhosttyKit.xcframework"
echo "==> Next: ./scripts/install-macos-app.sh"
