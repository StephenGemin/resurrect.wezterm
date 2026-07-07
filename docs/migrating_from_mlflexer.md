# Migrating from MLFlexer's resurrect.wezterm

This project is a fork of [MLFlexer's original `resurrect.wezterm`](https://github.com/MLFlexer/resurrect.wezterm),
which is now archived. The API is largely unchanged, but a few things moved or changed
behavior — this doc covers both moving your old saved sessions over and what behaves
differently once you're on the fork.

## Data migration

The default location where state files are saved has moved: it used to live inside the
plugin's own git-clone directory, and now lives in a fixed, OS-standard data directory
instead. That means **swapping only the `require()` URL will not bring your old saved
sessions forward** — they need to be copied over once.

1. *(Optional — only if you want your old saved sessions available here)* run the
   migration script to copy your old state files into the new default directory. It
   only copies files — it never touches your `wezterm.lua` or deletes anything, and
   never overwrites existing files at the destination:

   ```sh
   bash scripts/migrate-from-mlflexer.sh
   ```

   On Windows, run this from a Git Bash terminal (ships with
   [Git for Windows](https://git-scm.com/downloads/win)) — the script fails with a clear
   error rather than doing the wrong thing if Git Bash isn't available. If something
   looks off, its output is meant to be pasted directly into a GitHub issue.

2. Update the require URL in your `wezterm.lua`:

   ```lua
   local resurrect = wezterm.plugin.require("https://github.com/StephenGemin/resurrect.wezterm")
   ```

3. Restart WezTerm (or run `wezterm.reload_configuration()`).

4. Once you've confirmed your old sessions restore correctly, you can delete the old
   MLFlexer plugin directory manually.

### Migrating state files manually (optional)

Prefer not to run the script? Find your old plugin clone dir via `wezterm.plugin.list()`
in the Wezterm Debug Overlay (`Ctrl + Shift + L`), then copy its state files across
yourself:

| OS | Old location (inside the MLFlexer plugin clone) | New location |
|----|---------------------------------------------------|--------------|
| macOS | `<plugin clone dir>/state/` | `~/Library/Application Support/wezterm/resurrect/` |
| Linux | `<plugin clone dir>/state/` | `$XDG_DATA_HOME/wezterm/resurrect/` (or `~/.local/share/wezterm/resurrect/`) |
| Windows | `<plugin clone dir>\state\` | `%APPDATA%\wezterm\resurrect\` |

The saved-state JSON schema is unchanged, so copied files load without any conversion.

## Behavioral changes

| Behavior | MLFlexer | This fork |
|---|---|---|
| Restore switches to the workspace? | No — never switches | Yes, by default |
| `spawn_in_workspace` default | Doesn't exist — spawns untagged into the current workspace | `true` (tag into the saved name) |
| `switch_workspace` opt | Doesn't exist | Exists; defaults to following `spawn_in_workspace` |
| Reloading an already-live workspace | Duplicates the windows (no guard) | Switches to the live windows instead of duplicating |
| Error handling in restore | Unhandled — a thrown error aborts silently | Wrapped in `pcall`; failures emit `resurrect.error` |
| Unnamed/default workspace on save | Saved as whatever `get_active_workspace()` returns (may be empty) | Persisted as `"default"` |

### Why the switch-on-restore default

MLFlexer's own recommended keybinding recipes call `SwitchToWorkspace` immediately before
`restore_workspace` — so the desired end state (land in the restored workspace, with its
contents) was always the same; MLFlexer just left composing the switch to the user. This fork
builds that into `restore_workspace` itself via `spawn_in_workspace` + `switch_workspace`,
defaulting to "on" for backwards-compat-friendly behavior (see
[workspace_switching.md](./workspace_switching.md) for the full model).

### Getting the old (MLFlexer-style) behavior back

To restore into the current workspace without switching — the old default — set:

```lua
resurrect.workspace_state.restore_workspace(state, {
  spawn_in_workspace = false,
  switch_workspace = false,
})
```

See "Option B" in [`advanced-setup.lua`](./advanced-setup.lua) for this wired up as a
complete keybinding.
