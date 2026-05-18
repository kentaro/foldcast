#!/bin/bash
# Create a STABLE self-signed code-signing identity in a dedicated keychain.
# Stable identity => the app's designated requirement never changes across
# rebuilds => the Screen Recording (TCC) grant is given ONCE and then sticks.
# Fully non-interactive: uses its own keychain with a RANDOM password kept
# only in a local file outside the repo, so nothing secret is committed and
# it never needs your login keychain password.
set -euo pipefail

KC="$HOME/Library/Keychains/foldcast-signing.keychain-db"
PASS_FILE="$HOME/.foldcast/signing.pass"
CN="FoldCast Self Signed"

# Generate (once) and load the dedicated-keychain password.
mkdir -p "$(dirname "$PASS_FILE")"
if [ ! -s "$PASS_FILE" ]; then
  umask 077
  openssl rand -hex 24 > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
fi
KC_PASS="$(cat "$PASS_FILE")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v "$KC" 2>/dev/null | grep -q "$CN"; then
  echo "▸ signing identity already present: $CN"
  exit 0
fi

echo "▸ generating self-signed code-signing cert ($CN)"
cat > "$WORK/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = FoldCast Self Signed
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# LibreSSL (/usr/bin/openssl) emits Apple-compatible PKCS12 (SHA1 MAC + 3DES);
# OpenSSL 3's newer MAC fails `security import`.
SSL=/usr/bin/openssl

"$SSL" req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/openssl.cnf"

"$SSL" pkcs12 -export -out "$WORK/id.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$CN" -passout pass:"$KC_PASS"

# Dedicated keychain (created/owned by us, password we control).
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings "$KC"          # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$KC_PASS" \
  -T /usr/bin/codesign -A
# Allow codesign to use the key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KC_PASS" "$KC" >/dev/null 2>&1 || true
# Put it on the keychain search list so `codesign --sign "$CN"` resolves it.
EXIST=$(security list-keychains -d user | sed 's/[\" ]//g')
security list-keychains -d user -s "$KC" $EXIST

echo "▸ done. Identity:"
security find-identity -v "$KC" | grep "$CN" || true
