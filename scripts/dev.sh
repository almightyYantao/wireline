#!/usr/bin/env bash
# Hands-free dev loop for the pure-SwiftPM setup: watch Sources/, then rebuild a
# DEBUG bundle and relaunch on every save. Not instant hot reload (~5-7s), but
# fully automatic — edit a file and the app comes back updated.
#
# For *true* live hot reload, open Package.swift in Xcode, run (⌘R), and have
# InjectionIII running — the Inject wiring is already in place.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

reload() {
    if CONFIG=debug ./scripts/bundle.sh >/tmp/wireline-dev.log 2>&1; then
        pkill -x Wireline 2>/dev/null || true
        open build/Wireline.app
        echo "  ✓ reloaded $(date +%H:%M:%S)"
    else
        echo "  ✗ build failed — tail of /tmp/wireline-dev.log:"
        grep -E "error:" /tmp/wireline-dev.log | grep -v SwiftTerm | head -8 || tail -8 /tmp/wireline-dev.log
    fi
}

newest() { find Sources Package.swift -name '*.swift' -o -name 'Package.swift' 2>/dev/null \
    | xargs stat -f '%m' 2>/dev/null | sort -nr | head -1; }

echo "▸ Watching Sources/ — Ctrl-C to stop."
reload
last="$(newest)"
while true; do
    sleep 1
    now="$(newest)"
    if [[ "${now}" != "${last}" ]]; then
        last="${now}"
        echo "▸ change detected, rebuilding…"
        reload
    fi
done
