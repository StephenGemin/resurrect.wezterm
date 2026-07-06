# Using resurrect.wezterm with smart_workspace_switcher.wezterm

[smart_workspace_switcher.wezterm](https://github.com/MLFlexer/smart_workspace_switcher.wezterm)
is a companion plugin (same original author as this fork's upstream) that fuzzy-picks
existing workspaces *and* [zoxide](https://github.com/ajeetdsouza/zoxide)-tracked directories,
creating a new workspace named after the directory when you pick one that isn't already open.
It's **archived and no longer maintained**, but it's still commonly paired with
resurrect.wezterm, so this documents how to wire the two together and a fork-specific gotcha
you'll hit if you do.

## The integration pattern

resurrect.wezterm saves and restores state by workspace *name*. smart_workspace_switcher
assigns that name for you (the zoxide path, `~`-shortened) whenever it creates a new
workspace. Hooking its events lets you: save the workspace you're leaving, then restore the
one you're arriving at — so switching to a zoxide path effectively resumes that project's last
saved session.

```lua
local resurrect = wezterm.plugin.require("https://github.com/StephenGemin/resurrect.wezterm")

-- Fires while still in the workspace you're leaving, right as a choice is made
-- (before the switch happens) — the natural point to save its current state.
wezterm.on("smart_workspace_switcher.workspace_switcher.selected", function(window, id, label)
  resurrect.state_manager.save_state(resurrect.workspace_state.get_workspace_state())
end)
```

## The already-live guard skips restore on `created`

This fork's `restore_workspace` switches to a workspace's live windows instead of
re-materializing its snapshot whenever the workspace already has *any* live window (see
[`workspace-switching.md`](./workspace-switching.md)) — this avoids spawning duplicate
windows when you reload an already-open workspace.

That guard collides with `created`: by the time this event fires, `smart_workspace_switcher`
has already called `SwitchToWorkspace({ name = label, spawn = { cwd = path } })`, which spawns
a blank window in the new workspace *before* emitting the event. So a naive
`restore_workspace(...)` call inside a `created` handler finds that blank window already
tagged with the target name and just switches to it — the saved snapshot never gets applied.

**Workaround:** restore directly into the window `smart_workspace_switcher` already gave you,
bypassing `restore_workspace`'s guard, and spawn any additional saved windows yourself:

```lua
wezterm.on("smart_workspace_switcher.workspace_switcher.created", function(window, path, label)
  local state = resurrect.state_manager.load_state(label, "workspace")
  if not state.window_states or #state.window_states == 0 then
    -- No saved state for this workspace yet (first time visiting this project) --
    -- load_state logs a "file not found" error in this case; that's expected noise.
    return
  end

  local opts = {
    relative = true,
    restore_text = true,
    on_pane_restore = resurrect.tab_state.default_on_pane_restore,
  }

  resurrect.window_state.restore_window(window, state.window_states[1], opts)

  for i = 2, #state.window_states do
    local window_state = state.window_states[i]
    local _, _, new_window = wezterm.mux.spawn_window({
      workspace = label,
      width = window_state.size.cols,
      height = window_state.size.rows,
      cwd = window_state.tabs[1].pane_tree.cwd,
    })
    resurrect.window_state.restore_window(new_window, window_state, opts)
  end
end)
```

Switching to an **already-open** workspace (the `chosen` event) doesn't need a hook at all —
`restore_workspace`'s guard is what you want there, and you're not calling `restore_workspace`
from this integration in the first place.

## Ongoing autosave

The hooks above only handle the moment you switch. Once you're in a workspace, keep saving it
automatically via `event_driven_save`/`periodic_save` (wired up by `resurrect.setup()`, or see
[`advanced-setup.lua`](./advanced-setup.lua) for the manual equivalent) — no extra wiring
needed for that part.
