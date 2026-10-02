#!/usr/bin/env bash
# Generate the integration-test fixture: ~10 s of synthesized English speech as
# 16-bit PCM WAV, plus the exact reference text used for WER.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR="Core/Tests/VoiceToTextIntegrationTests/Fixtures"
WAV="$DIR/hello-10s.wav"
TXT="$DIR/hello-10s.txt"
TEXT="Hello, this is a quick test of the voice to text app. I am speaking a few short sentences so the speech model has something real to transcribe. The weather is nice today, and I would like a cup of coffee."

mkdir -p "$DIR"
printf '%s\n' "$TEXT" > "$TXT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say -o "$TMP/speech.aiff" "$TEXT"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/speech.aiff" "$WAV"
echo "==> Wrote $WAV and $TXT"
