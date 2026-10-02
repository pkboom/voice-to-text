#!/usr/bin/env bash
# Fallback only (used by bootstrap.sh when no Apple Development identity exists):
# create a self-signed code-signing certificate "VoiceToText Local Signing" in the
# login keychain. Trusting it for code signing is a one-time GUI step (see bootstrap.sh).
set -euo pipefail

NAME="VoiceToText Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf"
PASS="vtt-$$"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/cert.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -name "$NAME" -out "$TMP/cert.p12" -passout "pass:$PASS"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "==> Imported \"$NAME\". Trust it for Code Signing in Keychain Access (one-time GUI step)."
