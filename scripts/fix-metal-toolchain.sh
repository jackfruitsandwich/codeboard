#!/usr/bin/env bash
set -euo pipefail

EXPORT_DIR="${1:-/tmp/codeboard-metal-export}"
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ { print $3 }')"

if [[ -z "$XCODE_BUILD" ]]; then
  echo "error: could not determine the current Xcode build version."
  exit 1
fi

rm -rf "$EXPORT_DIR"

echo "==> Exporting Metal Toolchain bundle"
xcodebuild -downloadComponent MetalToolchain -exportPath "$EXPORT_DIR"

EXPORTED_BUNDLE="$(find "$EXPORT_DIR" -maxdepth 1 -type d -name 'MetalToolchain-*.exportedBundle' | head -n 1)"
if [[ -z "$EXPORTED_BUNDLE" ]]; then
  echo "error: exported Metal Toolchain bundle not found in $EXPORT_DIR"
  exit 1
fi

CURRENT_BUILD="$(plutil -extract buildUpdateVersion raw -o - "$EXPORTED_BUNDLE/ExportMetadata.plist")"
echo "==> Rewriting Metal Toolchain build tag: ${CURRENT_BUILD:-unknown} -> $XCODE_BUILD"
plutil -replace buildUpdateVersion -string "$XCODE_BUILD" "$EXPORTED_BUNDLE/ExportMetadata.plist"

echo "==> Importing Metal Toolchain bundle"
xcodebuild -importComponent MetalToolchain -importPath "$EXPORTED_BUNDLE"

echo "==> Verifying metal compiler"
xcrun -sdk macosx metal -v
