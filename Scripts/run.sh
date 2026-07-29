#!/usr/bin/env bash
#
# run.sh — build and launch.
#
# Once the app is installed, this updates the installed copy rather than running a second
# one out of build/. Two bundles with the same identifier is a good way to spend ten
# minutes wondering why a fix "did nothing": both register the hotkey, only one wins, and
# it is not necessarily the one just rebuilt.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLED="/Applications/PushToType.app"

if [[ -d "$INSTALLED" ]]; then
    # Already installed: keep that copy current, and leave the login item alone.
    exec "$ROOT/Scripts/install.sh" --no-login
fi

"$ROOT/Scripts/build-app.sh" "$@"

if pgrep -x PushToType >/dev/null 2>&1; then
    echo "==> Quitting the running instance"
    pkill -x PushToType || true
    sleep 0.5
fi

echo "==> Launching"
open "$ROOT/build/PushToType.app"
