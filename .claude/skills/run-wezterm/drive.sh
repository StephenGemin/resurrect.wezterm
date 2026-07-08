#!/usr/bin/env bash
# Drive a throwaway, isolated wezterm-gui instance to live-test uncommitted
# resurrect.wezterm changes, archiving every run's evidence and emitting a
# consistent report. See SKILL.md for the full workflow and rationale.
#
# Isolation guarantees (verified against wezterm 20240203-110809-5046fc22):
#   * A dedicated mux SOCKET per instance ($HOME/.local/share/wezterm/gui-sock-<pid>)
#     is the ONLY reliable way to target the test instance with `wezterm cli`.
#     `wezterm cli --class` does NOT isolate — it still hits whichever gui owns
#     the `default-*` socket symlink (your daily driver).
#   * A scratch STATE dir (change_state_save_dir in test-config.lua) so saves
#     never touch the user's real ~/Library/Application Support/wezterm/resurrect/.
#
# Each run gets an ephemeral archive dir under $TMPDIR (auto-cleaned by the OS):
#   <runs>/<timestamp>/
#     state/       scratch resurrect state (the saved JSON is itself evidence)
#     evidence/    cli-list snapshots + per-pid gui-log copies + plugin diff
#     meta.txt     wezterm version, git rev, the uncommitted diff under test
#     verdict.md   YOU write this: PASS/FAIL/INCONCLUSIVE + reasoning
#     report.md    generated: meta + verdict + restore log snippets + index
#
# Never kills the user's existing wezterm; only the pids it launched itself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CACHE_DIR="$HOME/Library/Application Support/wezterm/plugins/httpssCssZssZsgithubsDscomsZsStephenGeminsZsresurrectsDswezterm"
CONFIG="$SCRIPT_DIR/test-config.lua"
CLASS="resurrect-debug"

# Ephemeral so the OS reaps it; override with RESURRECT_DEBUG_RUNS for a stable dir.
RUNS_ROOT="${RESURRECT_DEBUG_RUNS:-${TMPDIR:-/tmp}/resurrect-wezterm-debug/runs}"
CURRENT="$RUNS_ROOT/.current"   # holds the path of the active run dir

sock_for() { echo "$HOME/.local/share/wezterm/gui-sock-$1"; }
run_dir()  { [ -f "$CURRENT" ] && cat "$CURRENT" || { echo "no active run (start one: $0 start)" >&2; exit 1; }; }
cur_pid()  { local r; r="$(run_dir)"; cat "$r/gui.pid"; }

# Fire the test-config.lua user-var-changed hook by having a pane's shell emit an
# OSC SetUserVar (base64 value). This drives the plugin's real restore/delete API
# without the fuzzy picker, which `wezterm cli` cannot navigate. See SKILL.md.
emit_uservar() {
	local name="$1" b64 sock pane
	b64="$(printf '%s' "$2" | base64)"
	sock="$(sock_for "$(cur_pid)")"
	pane="$(WEZTERM_UNIX_SOCKET="$sock" wezterm cli list --format json \
		| python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["pane_id"])')"
	WEZTERM_UNIX_SOCKET="$sock" wezterm cli send-text --pane-id "$pane" --no-paste \
		"printf '\033]1337;SetUserVar=$name=$b64\a'"$'\n'
}

copy_plugin() {
	[ -d "$CACHE_DIR/plugin/resurrect" ] || { echo "plugin cache not found: $CACHE_DIR" >&2; exit 1; }
	cp "$REPO_DIR/plugin/init.lua" "$REPO_DIR/plugin/types.lua" "$CACHE_DIR/plugin/"
	cp "$REPO_DIR"/plugin/resurrect/*.lua "$CACHE_DIR/plugin/resurrect/"
}

# Copy each launched instance's gui log into the run's evidence dir.
capture_logs() {
	local run="$1" pid
	[ -f "$run/pids.txt" ] || return 0
	while read -r pid; do
		cp "$HOME/.local/share/wezterm/wezterm-gui-log-$pid.txt" \
			"$run/evidence/wezterm-gui-log-$pid.txt" 2>/dev/null || true
	done <"$run/pids.txt"
}

launch() {
	local run="$1" state="$1/state/" pid sock
	mkdir -p "$state"
	# RESURRECT_DEBUG must survive `restart`: restart re-enters launch() from a fresh
	# shell that no longer carries the env var the original `start` was invoked with, yet
	# the gui-startup restore the firehose exists to trace only runs on that post-restart
	# process. Persist the opt-in into the run dir on first sight and reload it here, so
	# `RESURRECT_DEBUG=1 drive.sh start` keeps emitting across restarts while a bare
	# `start` stays quiet (no flag file -> nothing to reload).
	local debug_flag="$run/resurrect-debug.on"
	if [ -n "${RESURRECT_DEBUG:-}" ]; then
		printf '%s' "$RESURRECT_DEBUG" >"$debug_flag"
	elif [ -f "$debug_flag" ]; then
		RESURRECT_DEBUG="$(cat "$debug_flag")"
	fi
	# `env` is required, not decorative: bash recognizes assignment prefixes at parse
	# time, so the `${RESURRECT_DEBUG:+VAR=val}` word (which only looks like an assignment
	# after expansion) would be run as a command named `RESURRECT_DEBUG=1` -> "command not
	# found", and wezterm would never launch. `env` parses VAR=val args itself.
	env RESURRECT_TEST_STATE_DIR="$state" ${RESURRECT_DEBUG:+RESURRECT_DEBUG="$RESURRECT_DEBUG"} \
		wezterm --config-file "$CONFIG" start --class "$CLASS" --always-new-process -- zsh -f \
		>"$run/gui-stdout.log" 2>&1 &
	pid=$!
	echo "$pid" >>"$run/pids.txt"
	echo "$pid" >"$run/gui.pid"
	sock="$(sock_for "$pid")"
	for _ in $(seq 1 15); do
		sleep 1
		WEZTERM_UNIX_SOCKET="$sock" wezterm cli list >/dev/null 2>&1 && break
	done
	echo "pid=$pid"
	echo "socket=$sock"
	echo "gui-log=$HOME/.local/share/wezterm/wezterm-gui-log-$pid.txt"
	echo "state-dir=$state"
}

snapshot() {
	local run label seq
	run="$(run_dir)"; label="${1:-snapshot}"
	seq="$(printf '%02d' "$(( $(ls "$run/evidence"/*.cli-list.txt 2>/dev/null | wc -l) + 1 ))")"
	WEZTERM_UNIX_SOCKET="$(sock_for "$(cur_pid)")" wezterm cli list \
		>"$run/evidence/$seq-$label.cli-list.txt" 2>&1 || true
	capture_logs "$run"
}

generate_report() {
	local run="$1" out="$1/report.md"
	capture_logs "$run"
	{
		echo "# run-wezterm report — $(basename "$run")"
		echo
		echo "_Generated $(date '+%Y-%m-%d %H:%M:%S'). Evidence: \`$run\`_"
		echo
		echo "## Verdict & reasoning"
		echo
		if [ -f "$run/verdict.md" ]; then
			cat "$run/verdict.md"
		else
			echo "> _No verdict.md written. The agent records PASS / FAIL / INCONCLUSIVE"
			echo "> plus reasoning in \`$run/verdict.md\`, then regenerates this report._"
		fi
		echo
		echo "## Environment & change under test"
		echo
		echo '```'
		cat "$run/meta.txt" 2>/dev/null || echo "(no meta.txt)"
		echo '```'
		if [ -s "$run/evidence/plugin-under-test.diff" ]; then
			echo
			echo "Uncommitted \`plugin/\` diff exercised this run: \`evidence/plugin-under-test.diff\`."
		else
			echo
			echo "No uncommitted \`plugin/\` changes — this run exercised committed code (harness check only)."
		fi
		echo
		echo "## Restore evidence (log lines used to judge the run)"
		echo
		echo '```'
		grep -h -E 'resurrect' "$run"/evidence/wezterm-gui-log-*.txt 2>/dev/null \
			| grep -E 'gui-startup|restore_baseline|error|skipping|resurrect\.debug' || echo "(no resurrect restore/save lines captured)"
		echo '```'
		echo
		echo "## Saved state summary"
		echo
		local f count
		while IFS= read -r f; do
			if command -v jq >/dev/null 2>&1; then
				count="$(jq '[.. | .text? // empty] | length' "$f" 2>/dev/null || echo '?')"
			else
				count="?"
			fi
			echo "- \`${f#"$run"/}\` — $count captured text node(s)"
		done < <(find "$run/state" -name '*.json' ! -name '*.bak' 2>/dev/null | sort)
		[ -f "$run/state/current_state" ] && echo "- \`state/current_state\` → $(head -1 "$run/state/current_state") (workspace restore points here)"
		echo
		echo "## Evidence index"
		echo
		echo '```'
		( cd "$run" && find . -type f ! -name report.md | sort )
		echo '```'
	} >"$out"
	echo "$out"
}

case "${1:-}" in
start)
	copy_plugin
	RUN="$RUNS_ROOT/$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$RUN/evidence"
	echo "$RUN" >"$CURRENT"
	ln -sfn "$RUN" "$RUNS_ROOT/latest"
	{
		echo "run:        $(basename "$RUN")"
		echo "date:       $(date '+%Y-%m-%d %H:%M:%S')"
		echo "wezterm:    $(wezterm --version 2>/dev/null)"
		echo "repo:       $REPO_DIR"
		echo "git branch: $(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
		echo "git HEAD:   $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null)"
		echo "plugin diff --stat (uncommitted, under test):"
		git -C "$REPO_DIR" diff --stat -- plugin/ 2>/dev/null | sed 's/^/  /'
	} >"$RUN/meta.txt"
	git -C "$REPO_DIR" diff -- plugin/ >"$RUN/evidence/plugin-under-test.diff" 2>/dev/null || true
	echo "copied plugin/ into cache; launching isolated instance..."
	launch "$RUN"
	echo "run-dir=$RUN"
	;;
snapshot)
	shift
	snapshot "${1:-snapshot}"
	;;
restart)
	RUN="$(run_dir)"
	snapshot "pre-restart"
	pid="$(cur_pid)"; kill "$pid" 2>/dev/null || true
	for _ in 1 2 3; do sleep 1; ps -p "$pid" >/dev/null 2>&1 || break; done
	echo "killed $pid; relaunching to trigger gui-startup restore..."
	launch "$RUN"
	;;
restore)
	shift
	[ -n "${1:-}" ] || { echo "usage: $0 restore <workspace>" >&2; exit 1; }
	emit_uservar resurrect_test_restore "$1"
	echo "fired restore hook for '$1' (non-live workspace -> spawns; live -> switch-to-live guard, no spawn)"
	;;
delete)
	shift
	[ -n "${1:-}" ] || { echo "usage: $0 delete <workspace>" >&2; exit 1; }
	emit_uservar resurrect_test_delete "$1"
	echo "fired delete hook for '$1' (target a NON-active workspace or periodic-save re-creates its JSON)"
	;;
sock)
	sock_for "$(cur_pid)"
	;;
cli)
	shift
	WEZTERM_UNIX_SOCKET="$(sock_for "$(cur_pid)")" wezterm cli "$@"
	;;
debuglog)
	# Grep the plugin's resurrect.debug: firehose out of the current run's LIVE gui log
	# (fresher than the archived evidence copy). Optional arg is an extended-regex filter,
	# so an assertion is one line: `drive.sh debuglog 'decision=drop' | grep 'poll=1'`.
	# Only produces output when the instance was launched with RESURRECT_DEBUG=1.
	shift
	log="$HOME/.local/share/wezterm/wezterm-gui-log-$(cur_pid).txt"
	if [ -n "${1:-}" ]; then
		grep -h 'resurrect.debug:' "$log" 2>/dev/null | grep -E "$1" || true
	else
		grep -h 'resurrect.debug:' "$log" 2>/dev/null || true
	fi
	;;
report)
	generate_report "$(run_dir)"
	;;
stop)
	RUN="$(run_dir)"
	snapshot "final" || true
	report_path="$(generate_report "$RUN")"
	pid="$(cur_pid)"; kill "$pid" 2>/dev/null || true
	rm -f "$CURRENT"
	git -C "$CACHE_DIR" checkout -- . 2>/dev/null || true
	echo "killed $pid; reverted plugin cache clone."
	echo "report: $report_path"
	echo "archive (ephemeral, under \$TMPDIR): $RUN"
	;;
*)
	echo "usage: $0 {start|snapshot [label]|restart|restore <ws>|delete <ws>|cli <args>|debuglog [regex]|sock|report|stop}" >&2
	exit 1
	;;
esac
