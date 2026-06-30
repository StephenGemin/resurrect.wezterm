#!/usr/bin/env bash
# E2E smoke test: start WezTerm with the plugin and wait for the sentinel file.
# Pass when the sentinel appears within 15 seconds; fail on timeout.
#
# Expects to be run from the repo root.
# Caller sets DISPLAY=:99 on Linux before invoking this script.
set -euo pipefail

SENTINEL_UNIX="$(pwd)/.resurrect_e2e_sentinel"
rm -f "$SENTINEL_UNIX"

# WezTerm on Windows needs native OS paths; convert if running under Git Bash.
if command -v cygpath >/dev/null 2>&1; then
	export RESURRECT_REPO_PATH
	RESURRECT_REPO_PATH=$(cygpath -w "$(pwd)")
	export RESURRECT_SENTINEL
	RESURRECT_SENTINEL=$(cygpath -w "$SENTINEL_UNIX")
else
	export RESURRECT_REPO_PATH="$(pwd)"
	export RESURRECT_SENTINEL="$SENTINEL_UNIX"
fi

wezterm --config-file spec/e2e/wezterm_basic.lua start &
WEZTERM_PID=$!

cleanup() {
	kill "$WEZTERM_PID" 2>/dev/null || true
	rm -f "$SENTINEL_UNIX"
}
trap cleanup EXIT

for _ in $(seq 1 30); do
	if [ -s "$SENTINEL_UNIX" ]; then
		echo "OK: plugin loaded and gui-startup fired without error"
		exit 0
	fi
	sleep 0.5
done

echo "FAIL: plugin did not signal successful startup within 15 seconds"
exit 1
