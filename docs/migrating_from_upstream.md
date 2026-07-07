# Migrating from the original resurrect.wezterm

The [original project](https://github.com/MLFlexer/resurrect.wezterm) is archived. The API in
this fork is largely unchanged, but a few things moved or changed behavior — this doc covers
the behavioral differences and the one-time data migration needed to bring your old saved
sessions forward.

## Behavioral changes

| Behavior | Legacy | Current |
|---|---|---|
| Restore switches to the workspace? | No — never switches | Yes, by default |
| `spawn_in_workspace` default | Doesn't exist — spawns untagged into the current workspace | `true` (tag into the saved name) |
| `switch_workspace` opt | Doesn't exist | Exists; defaults to following `spawn_in_workspace` |
| Reloading an already-live workspace | Duplicates the windows (no guard) | Switches to the live windows instead of duplicating |
| Error handling in restore | Unhandled — a thrown error aborts silently | Wrapped in `pcall`; failures emit `resurrect.error` |
| Unnamed/default workspace on save | Saved as whatever `get_active_workspace()` returns (may be empty) | Persisted as `"default"` |

### Why the switch-on-restore default

The original project's recommended keybinding recipes call `SwitchToWorkspace` immediately
before `restore_workspace` — so the desired end state (land in the restored workspace, with its
contents) was always the same; composing the switch was just left to the user. This fork builds
that into `restore_workspace` itself via `spawn_in_workspace` + `switch_workspace`, defaulting
to "on" for backwards-compat-friendly behavior (see [workspace_switching.md](./workspace_switching.md)
for the full model).

### Getting the legacy behavior back

To restore into the current workspace without switching — the legacy default — set:

```lua
resurrect.workspace_state.restore_workspace(state, {
  spawn_in_workspace = false,
  switch_workspace = false,
})
```

See "Option B" in [`advanced_setup.lua`](./advanced_setup.lua) for this wired up as a
complete keybinding.

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
   plugin directory manually.

### Migrating state files manually (optional)

Prefer not to run the script? Find your old plugin clone dir via `wezterm.plugin.list()`
in the Wezterm Debug Overlay (`Ctrl + Shift + L`), then copy its state files across
yourself:

| OS | Old location (inside the original plugin clone) | New location |
|----|---------------------------------------------------|--------------|
| macOS | `<plugin clone dir>/state/` | `~/Library/Application Support/wezterm/resurrect/` |
| Linux | `<plugin clone dir>/state/` | `$XDG_DATA_HOME/wezterm/resurrect/` (or `~/.local/share/wezterm/resurrect/`) |
| Windows | `<plugin clone dir>\state\` | `%APPDATA%\wezterm\resurrect\` |

The saved-state JSON schema is unchanged, so copied files load without any conversion.
