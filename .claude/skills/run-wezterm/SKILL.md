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
./drive.sh start            # copies plugin/ into the cache, opens a fresh run archive,
                            # launches isolated gui, prints pid / socket / gui-log / run-dir
./drive.sh cli list         # run any `wezterm cli` subcommand against ONLY the test instance
./drive.sh snapshot <label> # capture cli-list + gui-log into the run archive at a named point
./drive.sh restart          # kill + relaunch -> fires gui-startup restore from saved state
./drive.sh restore <ws>     # headless fuzzy-restore <ws> into the LIVE instance (no picker)
./drive.sh delete <ws>      # headless fuzzy-delete <ws>'s saved state (no picker)
./drive.sh debuglog [regex] # grep the plugin's resurrect.debug: firehose (RESURRECT_DEBUG runs)
./drive.sh report           # (re)generate report.md from the archive; prints its path
./drive.sh stop             # snapshot + report, kill the gui, `git checkout -- .` the cache
```

`drive.sh` guarantees isolation two ways: it targets the test gui by its own
socket, and `test-config.lua` calls `change_state_save_dir()` to redirect all
saves into a per-run scratch dir so it never writes the user's real
`~/Library/Application Support/wezterm/resurrect/`.

Every run gets an **ephemeral archive** under `$TMPDIR` (auto-reaped by the OS —
no manual cleanup) at `…/resurrect-wezterm-debug/runs/<timestamp>/`, symlinked as
`runs/latest`. It holds the saved state JSON, per-pid gui-log copies, `cli list`
snapshots, the uncommitted diff under test, and the generated `report.md`.

## A full round trip (what to actually do)

```sh
cd .claude/skills/run-wezterm
./drive.sh start
RUN=$(readlink "${TMPDIR:-/tmp}/resurrect-wezterm-debug/runs/latest"); STATE="$RUN/state"

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

# 5. Record the judgment, then let stop assemble the report and print its path.
cat > "$RUN/verdict.md" <<'MD'
**PASS** — both marker panes restored after restart.
- <what you built / what you waited on / which evidence you checked>
MD
./drive.sh stop   # prints: report: <run>/report.md
```

A clean pass looks like: each `MARK_*` reappears after `restart`, and the gui log
(below) shows `restoring workspace '<name>' on gui-startup` followed by
`resurrect.restore_baseline: pane N registered replay ... settled`.

## The run report

`stop` (and `report`) writes `report.md` into the run archive and prints its path
— that path is the skill's final output; hand it to the user. The report has a
fixed shape so runs read the same every time:

- **Verdict & reasoning** — folded verbatim from `$RUN/verdict.md`, which YOU
  write: `PASS` / `FAIL` / `INCONCLUSIVE` plus how you decided. `drive.sh` never
  guesses the verdict; if `verdict.md` is absent the section says so.
- **Environment & change under test** — wezterm version, git branch/rev, and the
  `--stat` of the uncommitted `plugin/` diff this run exercised (full diff in
  `evidence/plugin-under-test.diff`). If the tree is clean it says the run only
  checked the harness, not a change.
- **Restore evidence** — the actual `resurrect …` gui-log lines used to judge the
  run (gui-startup restore, `restore_baseline` replay/settle, any error/skip).
- **Saved state summary** — each state JSON with its captured-text-node count, and
  where `current_state` points.
- **Evidence index** — every file in the archive, for deeper digging.

Write `verdict.md` **before** `stop`/`report` so it lands in the generated file.
Call `report` any time to regenerate after editing `verdict.md`.

## Reading evidence

- **gui log**: `~/.local/share/wezterm/wezterm-gui-log-<pid>.txt` (one per gui;
  `start`/`restart` print the path). Save/restore settle decisions are prefixed
  `resurrect.debug:` and only appear on a `RESURRECT_DEBUG=1` run (see Debug logging).
- **saved JSON**: `$STATE/{workspace,window,tab}/*.json`. Pane text lives under
  `window_states[].tabs[].pane_tree(.left/.right).text`. Compare captured text with:
  ```sh
  jq -c '[.. | .text? // empty]' "$STATE/workspace/<name>.json"
  ```
- **`current_state`**: `$STATE/current_state` holds the workspace name + type that
  `gui-startup` restore will load. No file = "skipping startup restore" (expected
  on a fresh instance before the first save).

## Debug logging (`resurrect.debug:` firehose)

The plugin has a gated diagnostic firehose for the internal-only signal nothing external
exposes — chiefly the restore settle/replay decisions in `restore_baseline.lua` (idle vs.
active, whether the replay is persisted or captured live). It is **off by default**. Turn it on
for a run by exporting the env var before `start`:

```sh
RESURRECT_DEBUG=1 ./drive.sh start      # this instance emits resurrect.debug: lines
./drive.sh debuglog                     # print them all from the live gui log
./drive.sh debuglog 'decision=drop'     # filter by field (extended regex)
```

Lines are single-line `key=value`, event token first, so you assert on a field in one pipe:

```sh
./drive.sh debuglog 'decision=drop' | grep 'poll=1' && echo "REGRESSION" || echo "ok"
```

A bare `./drive.sh start` (no env var) stays quiet — no firehose. The report's restore-evidence
block includes `resurrect.debug:` lines when present. To flip it on mid-session instead, run
`require("resurrect.logging").set_debug(true)` in the F12 debug overlay (an env var is frozen at
gui-process start; the setter mutates the cached module live).

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

## Driving the picker flows (restore / delete) without the fuzzy finder

`wezterm cli` (20240203) has **no key-event verb** and cannot navigate an
`InputSelector`, so the plugin's keybinding + picker flows can't be driven through
their UI:

- create workspace — `Alt+Shift+N` (`workspace_state.create_workspace_action`, name prompt)
- fuzzy restore/switch — `Alt+R` (`fuzzy_loader.restore_action`)
- fuzzy delete — `Alt+D` (`fuzzy_loader.delete_action`)

The picker, though, is a thin name-selection wrapper over already-public API. So
`test-config.lua` carries a **test-only** `user-var-changed` hook that calls the
**same** functions the picker's callback calls — bypassing only the selection UI, not
the restore/delete logic. `drive.sh restore <ws>` / `delete <ws>` trigger it by making
a pane's shell emit an OSC `SetUserVar` (the value is base64; it must reach the pane's
**stdout**, which is how shell integration sets user vars):

```sh
./drive.sh restore <ws>   # -> workspace_state.restore_workspace(load_state(<ws>,"workspace"), <picker opts>)
./drive.sh delete <ws>    # -> state_manager.delete_state("workspace/<ws>.json")
```

This is the one path a restart→gui-startup round trip does **not** cover: a
**live-switch restore** (`Alt+R` into a running instance), exactly what `#61/#64`
touched. What to know when using it:

- **Restore a NON-live workspace to see a spawn.** Restoring the currently-live
  workspace hits the `#61` switch-to-live guard (switches instead of duplicating —
  correct, but no new window). Build a second workspace, switch away, then restore.
- **Delete a NON-active workspace.** Periodic-save (10s) re-creates the active
  workspace's JSON right after you delete it.
- This bypasses the fuzzy finder; it does **not** test it. The filtering / selection /
  rendering UI glue is out of scope here — cover that with a targeted unit test, not by
  driving the overlay.
- Hook scope is **workspace** restore/delete (the skill's round-trip unit). Window/tab
  picker restores aren't wired up; add a branch to the hook if a test needs them.

## Cleanup / safety

`./drive.sh stop` kills only the pid it launched and runs `git checkout -- .` in
the plugin cache clone to drop the hand-copied files. **Never push or commit to
propagate a change into the cache** — the cache only reflects GitHub after a push
+ plugin update, and `wezterm.plugin.update_all()` would clobber hand-copied
files anyway. Run archives live under `$TMPDIR` and are reaped by the OS, so no
manual cleanup is needed; delete one early with `rm -rf "$RUN"` if you want.
