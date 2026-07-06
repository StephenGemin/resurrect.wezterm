# restore_opts

Options accepted by `restore_workspace`, `restore_window`, `restore_tab`, and `restore_action`:

```lua
{
  spawn_in_workspace: boolean?, -- Restores the windows into the saved workspace; default: true. Set false to spawn into the current workspace
  switch_workspace: boolean?,   -- Switch the active workspace to the restored one; defaults to the value of spawn_in_workspace
  relative: boolean?,           -- Size new pane splits as a fraction of their parent (recommended if the restoring window isn't the same size as when saved)
  absolute: boolean?,           -- Size new pane splits using the saved absolute row/column counts instead of a fraction
  close_open_tabs: boolean?,    -- Closes all tabs already open in the window, leaving only the restored ones
  close_open_panes: boolean?,   -- Closes all panes already open in the tab, leaving only the restored ones
  pane: Pane?,                  -- Reuse this pane as the tab's first pane instead of spawning a new one
  tab: MuxTab?,                 -- Reuse this tab as the window's first tab instead of spawning a new one
  window: MuxWindow,            -- Reuse this window instead of spawning a new one
  resize_window: boolean?,      -- Resize the window to the saved size; default: true
  on_pane_restore: fun(pane_tree: pane_tree), -- Function to restore panes; use resurrect.pane_tree.default_on_pane_restore
}
```

`spawn_in_workspace` and `switch_workspace` are workspace-only (`restore_window`/`restore_tab`
ignore them) and have enough nuance to warrant their own doc — see
[`workspace-switching.md`](./workspace-switching.md) for the full model, the current
`spawn`/`switch` behavior table, and the breaking-change note from earlier versions.

## Reusing an existing window, tab, or pane

`window`, `tab`, and `pane` cascade: passing `window` lets `restore_window` reuse that window
for the first saved window's contents instead of spawning a fresh one; within that, it reuses
the window's active tab as the first saved tab's contents (unless `close_open_tabs` is set,
which closes the window's other tabs instead); within that, it reuses the active pane as the
first saved pane (unless `close_open_panes` is set, which closes the tab's other panes
instead). This is what powers restoring into your current window — see "Option D" in
[`advanced-setup.lua`](./advanced-setup.lua).

Passing `tab` or `pane` directly (without `window`) is for narrower cases — e.g. reusing a
specific already-running tab or pane you already have a handle to, rather than the whole
window.

## Sizing: `relative` vs `absolute`

Pane splits can be sized as a fraction of their parent pane (`relative`) or by the saved
absolute row/column counts (`absolute`). `relative` is almost always what you want — it scales
correctly when the restoring window isn't the same size as when the state was saved.
`resize_window` (default `true`) additionally resizes the *window itself* to the saved size
before restoring its contents; set it to `false` if you've had trouble with `window_decorations`
or `window_padding` affecting resize behavior (see
[this comment](https://github.com/StephenGemin/resurrect.wezterm/issues/72#issuecomment-2582912347)).
