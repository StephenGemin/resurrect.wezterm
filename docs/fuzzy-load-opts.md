# fuzzy_load_opts

`resurrect.fuzzy_loader.fuzzy_load(window, pane, callback, opts?)` accepts an optional `opts`
argument to control picker appearance and filtering. `restore_action` and `delete_action` take
the same options via an `opts.fuzzy_load_opts` sub-table:

```lua
---@alias fmt_fun fun(label: string): string
---@alias fuzzy_load_opts {
  title: string,               -- dialog title, default: "Load state"
  description: string,         -- description shown above the picker, default: "Select State to Load and press Enter = accept, Esc = cancel, / = filter"
  fuzzy_description: string,   -- prompt shown in fuzzy mode; default: a nerdfonts.md_backup_restore glyph + "resurrect.wezterm · select state to restore: "
  is_fuzzy: boolean,           -- enter directly in fuzzy mode, default: true
  ignore_workspaces: boolean,  -- hide workspace entries, default: false
  ignore_tabs: boolean,        -- hide tab entries, default: false
  ignore_windows: boolean,     -- hide window entries, default: false
  fmt_window: fmt_fun,         -- format function for window state name (wezterm.format)
  fmt_workspace: fmt_fun,      -- format function for workspace state name
  fmt_tab: fmt_fun,            -- format function for tab state name
  fmt_date: fmt_fun,           -- format function for date
  show_state_with_date: boolean, -- show last update of the state file, default: false
  date_format: string,         -- date formatting, default: "%Y-%m-%d %H:%M"
  ignore_screen_width: boolean,-- whether to shrink the list if the window is too narrow, default: true
  name_truncature: string,     -- string used when state name is truncated
  min_filename_size: number    -- minimum size of state name before truncation
}
```

Example: showing only window states, with the last-saved date visible (used by "Option D" —
restore into the current window — in [`advanced-setup.lua`](./advanced-setup.lua) via
`ignore_workspaces`/`ignore_tabs`):

```lua
resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id) ... end, {
  ignore_workspaces = true,
  ignore_tabs = true,
  show_state_with_date = true,
})
```
