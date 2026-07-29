#!/usr/bin/env bash
#
# make-signing-identity.sh — create a local, self-signed code-signing identity.
#
# ## Why this exists
# macOS identifies an app for TCC (Microphone, Accessibility) by its code signature. An
# *ad-hoc* signature is just a hash of the binary, so every rebuild produces a different
# identity and every permission the user granted has to be granted again. During
# development that is a permission dialog per build.
#
# A self-signed certificate fixes it. The designated requirement becomes
#
#     identifier "com.gzowo.PushToType" and certificate leaf = H"<fixed hash>"
#
# which does not depend on the binary at all, so a grant survives every rebuild. The
# permission still has to be given once, for the first build signed this way.
#
# ## What this is not
# This is not a substitute for a Developer ID certificate. The identity is trusted by
# nothing and notarised by nobody: it makes local development bearable, and an app signed
# with it cannot be distributed to anyone else.
#
# Removing it again:
#     security delete-certificate -c "PushToType Local Signing"
#
set -euo pipefail

IDENTITY="${PUSHTOTYPE_SIGN_IDENTITY:-PushToType Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "==> '$IDENTITY' already exists in the login keychain"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    2>/dev/null

# macOS's Security framework cannot read PKCS#12 files written with OpenSSL 3's modern
# defaults (AES-256 + SHA-256 MAC). The older algorithms below are what `security import`
# understands; they protect a file that exists for the next two seconds.
echo "==> Packaging it"
openssl pkcs12 -export \
    -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$IDENTITY" -passout pass:local \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    2>/dev/null

echo "==> Importing into the login keychain"
# -T lets codesign use the key without a prompt on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P local -T /usr/bin/codesign >/dev/null

echo "==> Done. Rebuild with ./Scripts/build-app.sh, then grant Accessibility once more —"
echo "    it will stick from now on."
