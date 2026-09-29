#!/bin/bash
# Creates a local self-signed code-signing identity so every build of the app has the
# same signature. Without it, macOS treats each rebuild as a new app and silently drops
# its Accessibility / Microphone permissions. Run once; build.sh uses it automatically.
# Remove later with: Keychain Access → login → My Certificates → "Vibhor Notch Local Signing".
set -euo pipefail

NAME="Vibhor Notch Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Signing identity '$NAME' already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$(uuidgen)"

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -out "$TMP/identity.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout "pass:$PASS" 2>/dev/null

# -T lets codesign use the key without a keychain prompt on every build.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created signing identity '$NAME'."
