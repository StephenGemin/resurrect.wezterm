---
name: run-wezterm
description: Launch and drive a throwaway, isolated wezterm-gui instance to live-test uncommitted resurrect.wezterm plugin changes end-to-end. Use when asked to run, start, drive, or verify the plugin in a real WezTerm (a save → restart → restore round trip), not just via unit tests. Copies local plugin/ changes into the wezterm plugin cache, drives the instance with `wezterm cli`, and reads saved JSON + gui logs back as evidence.
---

# run-wezterm: live-debug resurrect.wezterm in a real WezTerm

Unit tests run the plugin under a `wezterm` mock. This skill runs the **real**
plugin inside a **real** wezterm-gui, so you can verify a genuine
save → restart → restore round trip. Everything here was verified against
`wezterm 20240203-110809-5046fc22`.

## The one non-obvious fact

`wezterm cli` targets an instance by its **per-process mux socket**, not by
`--class`. Each gui owns `~/.local/share/wezterm/gui-sock-<pid>`; bare
`wezterm cli` (and even `wezterm cli --class NAME`) follows the
`default-*.wezterm` symlink to the **daily-driver** instance. To drive the test
instance you MUST point `WEZTERM_UNIX_SOCKET` at its own `gui-sock-<pid>`.
`drive.sh` handles this for you.

## Quick start (use the driver)

```sh
cd .claude/skills/run-wezterm
./drive.sh start          # copies plugin/ into the cache, launches isolated gui,
                          # prints pid / socket / gui-log / state-dir
./drive.sh cli list       # run any `wezterm cli` subcommand against ONLY the test instance
./drive.sh restart        # kill + relaunch -> fires gui-startup restore from saved state
./drive.sh stop           # kill the test gui AND `git checkout -- .` the plugin cache
```

`drive.sh` guarantees isolation two ways: it targets the test gui by its own
socket, and `test-config.lua` calls `change_state_save_dir()` to redirect all
saves into a scratch dir (`$TMPDIR/resurrect-wezterm-debug/state/`) so it never
writes the user's real `~/Library/Application Support/wezterm/resurrect/`.

## A full round trip (what to actually do)

```sh
cd .claude/skills/run-wezterm
./drive.sh start
STATE="${TMPDIR:-/tmp}/resurrect-wezterm-debug/state"

# 1. Build a layout with recognizable markers. cli send-text goes to the shell,
#    so echo a unique token you can grep for after restore.
BASE=$(./drive.sh cli list --format json | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["pane_id"])')
./drive.sh cli send-text --pane-id "$BASE" --no-paste $'echo MARK_ALPHA\n'
R=$(./drive.sh cli split-pane --pane-id "$BASE" --bottom --percent 30)
./drive.sh cli send-text --pane-id "$R" --no-paste $'echo MARK_BETA\n'

# 2. WAIT for a save to actually contain your markers before killing. The
#    event_driven_save that fires on the split can land BEFORE the shell has
#    echoed the marker; periodic_save (10s in test-config.lua) re-captures it.
until grep -rq MARK_BETA "$STATE/workspace" 2>/dev/null; do sleep 1; done  # grep -r, not a glob: the dir/file may not exist yet, and a bare *.json glob is a hard error under zsh

# 3. Restart -> gui-startup restores the workspace named in `$STATE/current_state`.
./drive.sh restart

# 4. Assert. Restored scrollback often sits ABOVE the viewport, so read
#    scrollback with a negative --start-line, not the bare viewport.
for p in $(./drive.sh cli list --format json | python3 -c 'import json,sys;[print(x["pane_id"]) for x in json.load(sys.stdin)]'); do
  ./drive.sh cli get-text --pane-id "$p" --start-line -100 | grep -o 'MARK_[A-Z]*'
done

./drive.sh stop
```

A clean pass looks like: each `MARK_*` reappears after `restart`, and the gui log
(below) shows `restoring workspace '<name>' on gui-startup` followed by
`resurrect.restore_baseline: pane N registered replay ... settled`.

## Reading evidence

- **gui log**: `~/.local/share/wezterm/wezterm-gui-log-<pid>.txt` (one per gui;
  `start`/`restart` print the path). Restore verdicts are prefixed
  `resurrect.restore_baseline:`.
- **saved JSON**: `$STATE/{workspace,window,tab}/*.json`. Pane text lives under
  `window_states[].tabs[].pane_tree(.left/.right).text`. Compare captured text with:
  ```sh
  jq -c '[.. | .text? // empty]' "$STATE/workspace/<name>.json"
  ```
- **`current_state`**: `$STATE/current_state` holds the workspace name + type that
  `gui-startup` restore will load. No file = "skipping startup restore" (expected
  on a fresh instance before the first save).

## Gotchas verified the hard way

- **`--class` does not isolate `wezterm cli`.** Use the socket. (See top.)
- **`wezterm cli spawn` opens a new WINDOW in the `default` workspace**, not a tab
  in the current one. Use `split-pane` to grow the workspace you're testing.
- **The structural save can beat the echo.** Always gate your kill on the marker
  actually being in the JSON, per step 2 — don't just sleep.
- **`get-text` returns the viewport by default.** Replayed scrollback needs a
  negative `--start-line`.
- **A checksum change on the real state dir is NOT proof of a leak.** The user's
  daily-driver wezterm auto-saves on its own schedule while you work. To confirm
  isolation, grep the real dir for your test's fingerprints instead:
  ```sh
  grep -rl 'MARK_\|<your-test-workspace-name>' "$HOME/Library/Application Support/wezterm/resurrect" || echo clean
  ```

## Fallbacks (not part of the automated loop)

- **State `wezterm cli` can't see** (full window/tab/workspace layout, not just
  pane text): open the F12 debug overlay in the gui and query the **mux**:
  ```lua
  wezterm.mux.all_windows()[1]:active_tab():active_pane()
  ```
  Never `wezterm.gui.gui_windows()[1]:active_pane()` — with the overlay open the
  gui accessor returns the overlay pane itself (false negatives).
- **Visual-only checks** (colors, glyph rendering): screenshot a window by id.
  ```sh
  WID=$(osascript -e 'tell app "System Events" to id of window 1 of (first process whose name is "wezterm-gui")')
  screencapture -l"$WID" /tmp/wez.png
  ```
  Images can't be grepped/asserted on — prefer `get-text` for anything automatable.

## Cleanup / safety

`./drive.sh stop` kills only the pid it launched and runs `git checkout -- .` in
the plugin cache clone to drop the hand-copied files. **Never push or commit to
propagate a change into the cache** — the cache only reflects GitHub after a push
+ plugin update, and `wezterm.plugin.update_all()` would clobber hand-copied
files anyway. The scratch state dir is left for inspection; remove it with
`rm -rf "${TMPDIR:-/tmp}/resurrect-wezterm-debug"`.
