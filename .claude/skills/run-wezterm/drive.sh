#!/usr/bin/env bash
# Drive a throwaway, isolated wezterm-gui instance to live-test uncommitted
# resurrect.wezterm changes. See SKILL.md for the full workflow and rationale.
#
# Isolation guarantees (verified against wezterm 20240203-110809-5046fc22):
#   * A dedicated mux SOCKET per instance ($HOME/.local/share/wezterm/gui-sock-<pid>)
#     is the ONLY reliable way to target the test instance with `wezterm cli`.
#     `wezterm cli --class` does NOT isolate — it still hits whichever gui owns
#     the `default-*` socket symlink (your daily driver).
#   * A scratch STATE dir (change_state_save_dir in test-config.lua) so saves
#     never touch the user's real ~/Library/Application Support/wezterm/resurrect/.
#
# Never kills the user's existing wezterm; only the pid it launched itself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CACHE_DIR="$HOME/Library/Application Support/wezterm/plugins/httpssCssZssZsgithubsDscomsZsStephenGeminsZsresurrectsDswezterm"
CONFIG="$SCRIPT_DIR/test-config.lua"
CLASS="resurrect-debug"

RUN_DIR="${RESURRECT_DEBUG_RUN_DIR:-${TMPDIR:-/tmp}/resurrect-wezterm-debug}"
STATE_DIR="$RUN_DIR/state/"   # trailing slash: resurrect concatenates "workspace" etc.
PIDFILE="$RUN_DIR/gui.pid"

sock_for() { echo "$HOME/.local/share/wezterm/gui-sock-$1"; }

copy_plugin() {
	[ -d "$CACHE_DIR/plugin/resurrect" ] || { echo "plugin cache not found: $CACHE_DIR" >&2; exit 1; }
	cp "$REPO_DIR/plugin/init.lua" "$REPO_DIR/plugin/types.lua" "$CACHE_DIR/plugin/"
	cp "$REPO_DIR"/plugin/resurrect/*.lua "$CACHE_DIR/plugin/resurrect/"
}

launch() {
	mkdir -p "$STATE_DIR"
	RESURRECT_TEST_STATE_DIR="$STATE_DIR" \
		wezterm --config-file "$CONFIG" start --class "$CLASS" --always-new-process -- zsh -f \
		>"$RUN_DIR/gui-stdout.log" 2>&1 &
	local pid=$!
	echo "$pid" >"$PIDFILE"
	local sock; sock="$(sock_for "$pid")"
	for _ in $(seq 1 15); do
		sleep 1
		WEZTERM_UNIX_SOCKET="$sock" wezterm cli list >/dev/null 2>&1 && break
	done
	echo "pid=$pid"
	echo "socket=$sock"
	echo "gui-log=$HOME/.local/share/wezterm/wezterm-gui-log-$pid.txt"
	echo "state-dir=$STATE_DIR"
}

current_pid() { [ -f "$PIDFILE" ] && cat "$PIDFILE" || { echo "no running instance (run: $0 start)" >&2; exit 1; }; }

case "${1:-}" in
start)
	mkdir -p "$RUN_DIR"
	copy_plugin
	echo "copied plugin/ into cache; launching isolated instance..."
	launch
	;;
restart)
	# Kill (keep STATE_DIR) then relaunch so gui-startup restores from current_state.
	pid="$(current_pid)"; kill "$pid" 2>/dev/null || true
	for _ in 1 2 3; do sleep 1; ps -p "$pid" >/dev/null 2>&1 || break; done
	echo "killed $pid; relaunching to trigger gui-startup restore..."
	launch
	;;
sock)
	sock_for "$(current_pid)"
	;;
cli)
	shift
	WEZTERM_UNIX_SOCKET="$(sock_for "$(current_pid)")" wezterm cli "$@"
	;;
stop)
	pid="$(current_pid)"; kill "$pid" 2>/dev/null || true
	rm -f "$PIDFILE"
	git -C "$CACHE_DIR" checkout -- . 2>/dev/null || true
	echo "killed $pid; reverted plugin cache clone."
	echo "state dir left for inspection: $STATE_DIR (rm -rf \"$RUN_DIR\" to clear)"
	;;
*)
	echo "usage: $0 {start|restart|sock|cli <args>|stop}" >&2
	exit 1
	;;
esac
