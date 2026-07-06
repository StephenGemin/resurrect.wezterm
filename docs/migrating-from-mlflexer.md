# Behavioral differences from MLFlexer's resurrect.wezterm

This fork's `restore_workspace` behaves differently from
[MLFlexer's original](https://github.com/MLFlexer/resurrect.wezterm) by design. This page
covers the *behavioral* differences — for moving your old saved-state files to the new
storage location, see the [migration steps in the README](../README.md#migrating-from-mlflexers-resurrectwezterm).

| Behavior | MLFlexer | This fork |
|---|---|---|
| Restore switches to the workspace? | No — never switches | Yes, by default |
| `spawn_in_workspace` default | Doesn't exist — spawns untagged into the current workspace | `true` (tag into the saved name) |
| `switch_workspace` opt | Doesn't exist | Exists; defaults to following `spawn_in_workspace` |
| Reloading an already-live workspace | Duplicates the windows (no guard) | Switches to the live windows instead of duplicating |
| Error handling in restore | Unhandled — a thrown error aborts silently | Wrapped in `pcall`; failures emit `resurrect.error` |
| Unnamed/default workspace on save | Saved as whatever `get_active_workspace()` returns (may be empty) | Persisted as `"default"` |

## Why the switch-on-restore default

MLFlexer's own recommended keybinding recipes call `SwitchToWorkspace` immediately before
`restore_workspace` — so the desired end state (land in the restored workspace, with its
contents) was always the same; MLFlexer just left composing the switch to the user. This fork
builds that into `restore_workspace` itself via `spawn_in_workspace` + `switch_workspace`,
defaulting to "on" for backwards-compat-friendly behavior (see
[workspace-switching.md](./workspace-switching.md) for the full model).

## Getting the old (MLFlexer-style) behavior back

To restore into the current workspace without switching — the old default — set:

```lua
resurrect.workspace_state.restore_workspace(state, {
  spawn_in_workspace = false,
  switch_workspace = false,
})
```

See [`examples/restore-no-switch.lua`](./examples/restore-no-switch.lua) for a complete
snippet.
