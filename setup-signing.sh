#!/bin/bash
# One-time setup: create a self-signed "Hover Local Dev" code-signing identity in
# your login keychain.
#
# Why: with a stable signing identity, rebuilding Hover keeps the SAME signature,
# so macOS remembers your Microphone / Screen-Recording permission across rebuilds
# (ad-hoc signing changes every build and makes macOS re-ask).
#
# Run once:   ./setup-signing.sh
# Then:       ./build.sh          (build.sh picks up this identity automatically)
set -e

IDENTITY="Hover Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "'$IDENTITY' already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Creating a self-signed code-signing certificate '$IDENTITY'…"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=$IDENTITY" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"

# -legacy: OpenSSL 3 defaults to encryption Apple's `security import` can't read,
# so use the legacy PKCS#12 algorithms macOS understands.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/hover.p12" -passout pass:hover -name "$IDENTITY"

echo "Importing into your login keychain (you may be asked for your Mac password)…"
security import "$TMP/hover.p12" -k "$KEYCHAIN" -P hover -T /usr/bin/codesign

# Trust the self-signed cert for code signing, otherwise it shows up as
# "not trusted" and codesign refuses to use it. This pops a "changing your
# Certificate Trust Settings" prompt — enter your Mac password to approve.
echo "Trusting the certificate for code signing (approve the password prompt)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

# Let codesign use the new key without a popup on every build. This needs your
# login password; if it can't set it non-interactively, the first ./build.sh will
# simply ask you to "Always Allow" once — either way is fine.
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 \
  || echo "Note: the first ./build.sh may ask you to allow codesign to use the key — click \"Always Allow\"."

echo
echo "Done. Run ./build.sh — it will now sign Hover as '$IDENTITY'."
