#!/usr/bin/env bash
#
# run.sh — build the app, replace any running copy, and launch it.
#
# Quitting the old instance first matters: two copies would both register the global
# hotkey, and only one of them would ever receive it.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/Scripts/build-app.sh" "$@"

if pgrep -x PushToType >/dev/null 2>&1; then
    echo "==> Quitting the running instance"
    pkill -x PushToType || true
    sleep 0.5
fi

echo "==> Launching"
open "$ROOT/build/PushToType.app"
