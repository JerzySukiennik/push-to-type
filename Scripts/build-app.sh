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
# TCC (microphone, Accessibility) identifies an app by its code signature. An ad-hoc
# signature is stable as long as the binary does not change — which means a rebuild asks
# for Accessibility again. That is a property of unsigned local builds, not a bug; sign
# with a Developer ID certificate to make the grants stick across builds.
echo "==> Signing (ad-hoc)"
codesign --force --sign - \
    --entitlements "$ROOT/Resources/PushToType.entitlements" \
    --timestamp=none \
    "$APP" 2>/dev/null

echo "==> Done: $APP"
echo "    open $APP"
