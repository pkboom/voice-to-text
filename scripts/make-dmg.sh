#!/usr/bin/env bash
# Builds a Release VoiceToText.app signed with the `make bootstrap` identity and packages it with an
# /Applications link as build/dmg/VoiceToText.dmg, laid out by scripts/dmg/settings.py (artwork from
# scripts/make-art.py). Not notarized: recipients approve it once in System Settings > Privacy &
# Security (the window background says so).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${VTT_SIGN_IDENTITY:-$(cat "$ROOT/.signing-identity" 2>/dev/null || true)}"
[[ -n "$IDENTITY" ]] || { echo "!! No signing identity; run make bootstrap" >&2; exit 1; }

APP="$ROOT/build/dmg-release/Build/Products/Release/VoiceToText.app"
DMG="$ROOT/build/dmg/VoiceToText.dmg"

echo "[make-dmg] building Release"
(cd "$ROOT" && xcodegen generate --quiet)
xcodebuild build -project "$ROOT/VoiceToText.xcodeproj" -scheme VoiceToText -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$ROOT/build/dmg-release" VTT_SIGN_IDENTITY="$IDENTITY" -quiet

echo "[make-dmg] packaging"
# dmgbuild writes the Finder layout (background, icon positions) without scripting Finder.
VENV="$ROOT/build/.dmg-venv"
[[ -x "$VENV/bin/dmgbuild" ]] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q dmgbuild; }
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg/settings.py" -D app="$APP" -D art="$ROOT/scripts/dmg" "VoiceToText" "$DMG" >/dev/null

echo "[make-dmg] verifying"
mount="$(mktemp -d "${TMPDIR:-/tmp}/vtt-dmg-mount.XXXXXX")"
hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$DMG" >/dev/null
status=0
[[ -d "$mount/VoiceToText.app" ]] || { echo "!! VoiceToText.app missing from the image" >&2; status=1; }
[[ -L "$mount/Applications" ]] || { echo "!! /Applications link missing" >&2; status=1; }
codesign --verify --deep --strict "$mount/VoiceToText.app" || status=1
hdiutil detach "$mount" -quiet
rmdir "$mount" 2>/dev/null || true
((status == 0)) || exit 1
echo "[make-dmg] $DMG"
