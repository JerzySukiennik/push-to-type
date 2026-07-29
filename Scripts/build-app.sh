#!/usr/bin/env bash
#
# build-app.sh — build PushToType and assemble a real .app bundle.
#
#   ./Scripts/build-app.sh            release build → build/PushToType.app
#   ./Scripts/build-app.sh --debug    debug build (faster to compile, slower to run)
#
# Why a script instead of an Xcode project: this machine has only the Command Line Tools,
# so there is no xcodebuild. SwiftPM produces the executable; the bundle around it is four
# directories, an Info.plist and a signature. The result is a normal macOS app — Finder,
# Launch Services and TCC treat it exactly like an Xcode-built one.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIGURATION="debug"
fi

APP="$ROOT/build/PushToType.app"
CONTENTS="$APP/Contents"

# 1. whisper.cpp — skipped when the archives are already there.
if [[ ! -f "$ROOT/.build/whisper/lib/libwhisper.a" ]]; then
    echo "==> whisper.cpp not built yet"
    "$ROOT/Scripts/build-whisper.sh"
fi

# 2. The executable.
echo "==> Building PushToType ($CONFIGURATION)"
swift build -c "$CONFIGURATION"
EXECUTABLE="$(swift build -c "$CONFIGURATION" --show-bin-path)/PushToType"

# 3. The bundle.
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$EXECUTABLE" "$CONTENTS/MacOS/PushToType"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

# 4. Signature.
#
# TCC identifies an app by its code signature. An ad-hoc signature is a hash of the binary,
# so every rebuild is a different app as far as Microphone and Accessibility are concerned,
# and every permission has to be granted again.
#
# If the local self-signed identity exists (Scripts/make-signing-identity.sh), use it: its
# designated requirement is the bundle ID plus a fixed certificate hash, which does not
# change when the code does. Otherwise fall back to ad-hoc and say what that costs.
IDENTITY="${PUSHTOTYPE_SIGN_IDENTITY:-PushToType Local Signing}"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "==> Signing with '$IDENTITY'"
    SIGN_WITH="$IDENTITY"
else
    echo "==> Signing (ad-hoc) — permissions will reset on every rebuild."
    echo "    Run ./Scripts/make-signing-identity.sh once to stop that."
    SIGN_WITH="-"
fi

codesign --force --sign "$SIGN_WITH" \
    --entitlements "$ROOT/Resources/PushToType.entitlements" \
    --timestamp=none \
    "$APP" 2>/dev/null

echo "==> Done: $APP"
echo "    open $APP"
