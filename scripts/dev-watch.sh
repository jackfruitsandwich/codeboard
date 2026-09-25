#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INTERVAL="${CODEBOARD_DEV_INTERVAL:-1}"

fingerprint() {
  {
    find "$ROOT_DIR/Sources" -type f -name '*.swift' -print
    printf '%s\n' "$ROOT_DIR/Package.swift"
  } | sort | while IFS= read -r file; do
    [[ -e "$file" ]] && stat -f '%m %z %N' "$file"
  done | shasum -a 256
}

echo "Watching Codeboard sources and building only. Reload explicitly with ./scripts/codeboardctl reload."
swift build
last_fingerprint="$(fingerprint)"

while sleep "$INTERVAL"; do
  current_fingerprint="$(fingerprint)"
  if [[ "$current_fingerprint" != "$last_fingerprint" ]]; then
    echo "Change detected; building Codeboard without reloading..."
    if (cd "$ROOT_DIR" && swift build); then
      last_fingerprint="$current_fingerprint"
    fi
  fi
done
