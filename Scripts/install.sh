#!/usr/bin/env bash
#
# install.sh — build PushToType, put it in /Applications, and start it at login.
#
#   ./Scripts/install.sh              install and enable Launch at Login
#   ./Scripts/install.sh --no-login   install only
#
# Why /Applications and not the project directory: an app that lives in build/ is deleted
# by the next `swift build --clean`, is invisible to Spotlight, and confuses macOS about
# whether two copies are the same program. A tool you use every day belongs where tools go.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="/Applications/PushToType.app"

ENABLE_LOGIN_ITEM=1
if [[ "${1:-}" == "--no-login" ]]; then
    ENABLE_LOGIN_ITEM=0
fi

"$ROOT/Scripts/build-app.sh"

# A running copy holds the hotkey and would keep the old binary alive. Kill every copy and
# wait for them to actually go — a gentle pkill that returns before the process exits was
# how two instances ended up running at once.
if pgrep -x PushToType >/dev/null 2>&1; then
    echo "==> Quitting running instances"
    pkill -9 -x PushToType || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x PushToType >/dev/null 2>&1 || break
        sleep 0.2
    done
fi

echo "==> Installing to $DESTINATION"
rm -rf "$DESTINATION"
cp -R "$ROOT/build/PushToType.app" "$DESTINATION"

# Launch Services caches bundle metadata by path; registering explicitly means the new
# copy is recognised immediately rather than whenever the system next rescans.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DESTINATION" 2>/dev/null || true

if [[ "$ENABLE_LOGIN_ITEM" == "1" ]]; then
    echo "==> Enabling Launch at Login"
    # SMAppService can only register the app that calls it, so the app is asked to do it.
    "$DESTINATION/Contents/MacOS/PushToType" --register-login-item || {
        echo "    Could not enable it automatically — use the menu bar item instead."
    }
fi

echo "==> Launching"
open "$DESTINATION"

echo
echo "Installed. PushToType now lives in /Applications and starts with the system."
echo "Permissions carry over: TCC matches the code signature, not the path — as long as"
echo "the build is signed with the local identity rather than ad-hoc."
