#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET_DIR="$HOME/Library/Application Support/com.jackdigilov.codeboard"
TARGET_FILE="$TARGET_DIR/config.ghostty"

if [[ $# -ge 1 ]]; then
  SOURCE_FILE="$1"
  if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "error: config file not found: $SOURCE_FILE"
    exit 1
  fi

  mkdir -p "$TARGET_DIR"
  cp "$SOURCE_FILE" "$TARGET_FILE"
  echo "Copied:"
  echo "  from: $SOURCE_FILE"
  echo "  to:   $TARGET_FILE"
  exit 0
fi

declare -a CANDIDATES=(
  "$HOME/Library/Application Support/com.mitchellh.ghostty/config"
  "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
  "$HOME/.config/ghostty/config"
  "$HOME/.config/ghostty/config.ghostty"
)

SOURCE_FILE=""
for candidate in "${CANDIDATES[@]}"; do
  if [[ -f "$candidate" ]]; then
    SOURCE_FILE="$candidate"
    break
  fi
done

if [[ -z "$SOURCE_FILE" ]]; then
  echo "error: no Ghostty config file found."
  echo "Checked:"
  printf '  %s\n' "${CANDIDATES[@]}"
  echo
  echo "If your Ghostty config lives somewhere else, run:"
  echo "  ./scripts/copy-ghostty-config.sh /full/path/to/config.ghostty"
  exit 1
fi

mkdir -p "$TARGET_DIR"
cp "$SOURCE_FILE" "$TARGET_FILE"

echo "Copied:"
echo "  from: $SOURCE_FILE"
echo "  to:   $TARGET_FILE"
