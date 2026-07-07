# Workspace switching: the live/not-live model

This explains how `restore_workspace` decides whether to switch you into a workspace, and
why loading an already-open workspace doesn't re-apply the saved snapshot on top of it.

## Live vs. saved state

- **Live mux state** is wezterm's running engine — the actual windows/tabs/panes with real
  PTYs and processes (`wezterm.mux.all_windows()`).
- A **workspace** is just a label stamped on live windows (`mux_win:get_workspace()`). It
  exists only while at least one live window carries the name.
- **Saved state** is inert JSON on disk (`resurrect/workspace/<name>.json`) — sizes, layout,
  cwds, captured scrollback text. No running processes.
- **Restoring** materializes that JSON into *new* live windows.

## Why loading a live workspace doesn't re-apply the snapshot

If the target workspace already has live windows, `restore_workspace` switches you to those
live windows instead of spawning from disk. This is intentional, not a missed refresh:

- The snapshot was written *from* those same live windows, so the live version is always at
  least as fresh (plus real processes and full scrollback the snapshot can't reconstruct).
- The snapshot's job is cold start — restoring after quit/crash/reboot when the mux is empty.
  It isn't meant to be re-applied every time you hop between already-open workspaces.
- Older versions spawned the snapshot's windows *on top of* the live ones every time you
  reloaded, which duplicated windows on every load (they'd pile up over a session). That
  duplication is what this guard replaces.

## The two opts

`restore_workspace` (and `restore_action`) take two related options:

- `spawn_in_workspace` (default `true`) — tag the restored windows into the saved workspace
  name, instead of spawning into whatever workspace is currently active.
- `switch_workspace` (default: follows `spawn_in_workspace` when unset) — switch the GUI's
  active workspace to the restored one.

These aren't fully independent — they express one intent ("land in the restored workspace"
vs. "leave it running in the background") through two knobs.

## Current behavior

| `spawn_in_workspace` | `switch_workspace` | Target already live? | Result |
|---|---|---|---|
| `true` (default) | `true` / unset | no | Tag windows into the target, switch to it — you land in it. |
| `true` | `false` | no | Tag windows into the target, stay put — populates the workspace in the background. |
| `false` | `false` / unset | no | Spawn into the current workspace, then rename it to the target name (legacy in-place restore, matches the old default).[^1] |
| `false` | `true` | no | Spawn into the target instead of the current workspace, then switch to it. |
| *any* | resolved | **yes** | Switch to the live workspace (or stay, if `switch_workspace = false`) — no duplicate windows are spawned. |

Every combination of `spawn_in_workspace`/`switch_workspace` is coherent — the switch intent
always determines where the windows actually land, so there's no unsupported combination to
avoid.

[^1]: This path is additive, not a fresh restore: the restored window is spawned alongside
    whatever the current workspace already contains, and the rename then applies to that
    combined set. If you autosave (periodic or on-focus-loss) after this, the saved file for
    the target name grows to include the pre-existing windows too — and grows again each time
    you repeat the cycle. This is inherent to spawn-into-current + rename-whole-workspace, not
    a bug; avoid pointing `spawn_in_workspace = false` at a workspace name you also autosave.

## Scope

The already-live guard and `spawn_in_workspace` only apply to `restore_workspace`. `restore_window`
and `restore_tab` take an explicit window/tab handle you hand them, so there's no
workspace-level "already live?" question to guard against.
