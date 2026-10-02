#!/usr/bin/env bash
# Replace the installed app with the fresh Debug build and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="build/Build/Products/Debug/VoiceToText.app"
DEST="$HOME/Applications/VoiceToText.app"

[[ -d "$SRC" ]] || { echo "!! $SRC not found; run make build" >&2; exit 1; }

pkill -x VoiceToText || true
for _ in $(seq 1 50); do pgrep -x VoiceToText >/dev/null || break; sleep 0.1; done

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
codesign --verify --strict --verbose=2 "$DEST"
open "$DEST"
echo "==> Installed and launched $DEST"
