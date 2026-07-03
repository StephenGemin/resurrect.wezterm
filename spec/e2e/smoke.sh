#!/usr/bin/env bash
# E2E smoke test: start WezTerm with the given config and wait for the sentinel.
# Usage: bash spec/e2e/smoke.sh <config-file>
# Pass when sentinel contains "ok"; fail on timeout or sentinel containing "fail:".
#
# Expects to be run from the repo root.
# Caller sets DISPLAY=:99 on Linux before invoking this script.
set -euo pipefail

CONFIG="${1:?usage: smoke.sh <config-file>}"
SENTINEL_UNIX="$(pwd)/.resurrect_e2e_sentinel"
SAVE_DIR_UNIX="$(pwd)/.resurrect_e2e_state/"
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

wezterm --config-file "$CONFIG" start &
WEZTERM_PID=$!

cleanup() {
	kill "$WEZTERM_PID" 2>/dev/null || true
	rm -f "$SENTINEL_UNIX"
	rm -rf "$SAVE_DIR_UNIX"
}
trap cleanup EXIT

for _ in $(seq 1 30); do
	if [ -s "$SENTINEL_UNIX" ]; then
		result=$(cat "$SENTINEL_UNIX")
		echo "$result"
		if [ "$result" = "ok" ]; then
			exit 0
		else
			exit 1
		fi
	fi
	sleep 0.5
done

echo "FAIL: plugin did not signal successful startup within 15 seconds"
exit 1
