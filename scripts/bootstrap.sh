#!/usr/bin/env bash
# One-time setup: install XcodeGen and choose a stable code-signing identity.
# The chosen identity's SHA-1 is written to .signing-identity (gitignored) and
# read by the Makefile as VTT_SIGN_IDENTITY.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> Installing xcodegen via Homebrew"
  brew install xcodegen
else
  echo "==> xcodegen present: $(xcodegen --version)"
fi

pick_identity() {
  # $1 = regex matched against the identity name. Prints the first matching SHA-1.
  security find-identity -v -p codesigning \
    | awk -v pat="$1" '$0 ~ pat { print $2; exit }'
}

SHA="$(pick_identity '"Apple Development: ')"
if [[ -n "$SHA" ]]; then
  echo "==> Using existing Apple Development identity $SHA"
else
  SHA="$(pick_identity '"VoiceToText Local Signing"')"
  if [[ -z "$SHA" ]]; then
    echo "==> No Apple Development identity found; creating a self-signed one"
    scripts/create-signing-identity.sh
    SHA="$(pick_identity '"VoiceToText Local Signing"')"
  fi
  if [[ -z "$SHA" ]]; then
    cat <<'MSG'
!! The "VoiceToText Local Signing" certificate exists but is not yet trusted for code signing.
   One-time GUI step: open Keychain Access, double-click "VoiceToText Local Signing",
   expand Trust, set "Code Signing" to "Always Trust", close the window and authenticate.
   Then re-run: make bootstrap
MSG
    exit 1
  fi
  echo "==> Using self-signed identity $SHA"
fi

echo "$SHA" > .signing-identity
echo "==> Wrote .signing-identity ($SHA)"
echo "==> Note: if you ever switch to the self-signed fallback, trusting it in Keychain Access is a one-time GUI step."
