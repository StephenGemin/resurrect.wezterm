# resurrect.wezterm

Resurrect your terminal environment!⚰️ A plugin to save the state of your windows, tabs and panes. Inspired by [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) and [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum).

![Screencastfrom2024-07-2918-50-57-ezgif com-resize](https://github.com/user-attachments/assets/640aefea-793c-486d-9579-1a9c8bb4c1fa)

## Table of Contents

- [Features](#features)
- [Basic Setup](#basic-setup)
  - [Setup Options](#setup-options)
- [Advanced Setup](#advanced-setup)
  - [Resurrecting on startup](#resurrecting-on-startup)
  - [Saving state](#saving-state)
  - [Restoring state](#restoring-state)
  - [Deleting state](#deleting-state)
  - [Encryption (optional, recommended)](#encryption-optional-recommended)
- [Configuration](#configuration)
  - [Configuration reference](#configuration-reference)
  - [Change the directory to store the saved state](#change-the-directory-to-store-the-saved-state)
  - [Events](#events)
- [State files](#state-files)
- [Augmenting the command palette](#augmenting-the-command-palette)
- [FAQ](#faq)
- [Contributions](#contributions)
- [Disclaimer](#disclaimer)

## Features

- Restore your windows, tabs and panes with the layout and text from a saved state.
- Restore shell output from a saved session.
- Save the state of your current window, with every window, tab and pane state stored in a `json` file.
- Restore the save from a `json` file.
- Re-attach to remote domains (e.g. SSH, SSHMUX, WSL, Docker, ect.).
- Optionally enable encryption and decryption of the saved state.

## Basic Setup

```lua
local wezterm = require("wezterm")
local config = wezterm.config_builder()
local resurrect = wezterm.plugin.require("https://github.com/StephenGemin/resurrect.wezterm")

-- your existing config here (colors, fonts, shell, etc.)

resurrect.setup(config)

return config
```

### Setup Options

`setup()` handles autosave, startup restore, status bar, and keybindings — no hand-rolled
callbacks needed. All options are optional:

```lua
resurrect.setup(config, {
  periodic_interval = 300,   -- seconds between periodic saves
  restore_delay     = 0,     -- seconds to wait before sending process-restore commands
  save_workspaces   = true,
  save_windows      = true,
  save_tabs         = true,
  keybindings       = true,  -- set false to define your own (see below)
  status_bar        = true,  -- show last save time and tab titles in the right status bar
})
```

When `keybindings = true`, the following bindings are added:

| Key | Action |
|-----|--------|
| `Alt+W` | Save workspace |
| `Alt+S` | Save workspace + current window |
| `Alt+Shift+W` | Save window (prompts for name on first use) |
| `Alt+Shift+T` | Save tab (prompts for name on first use) |
| `Alt+R` | Fuzzy restore saved state |
| `Alt+D` | Fuzzy delete saved state |

> [!NOTE]
> `save_windows` and `save_tabs` only auto-save entities you have explicitly named via
> `save_window_action()` (`Alt+Shift+W`) or `save_tab_action()` (`Alt+Shift+T`). Unnamed
> windows and tabs are skipped. Workspaces always save; an unnamed workspace saves under
> its WezTerm name (default: `"default"`). Saving to a name that already exists overwrites
> the file — this applies to all three types.

To define your own keybindings, set `keybindings = false` and see [Saving state](#saving-state),
[Restoring state](#restoring-state), and [Deleting state](#deleting-state) in Advanced Setup.

## Advanced Setup

If you need fine-grained control over each component, you can configure them individually instead of using `setup()`.

### Resurrecting on startup

Resume from your last session automatically by adding this to your config:

```lua
wezterm.on("gui-startup", resurrect.state_manager.resurrect_on_gui_startup)
```

This reads the current state file written by `periodic_save` and `event_driven_save`
whenever `save_workspaces = true`. `setup()` wires this up automatically — only add
it manually if you are not using `setup()`.

### Saving state

Bind save actions to keys. Each action function takes no arguments — the naming prompt
and silent re-save behaviour are handled automatically (see the note below):

```lua
local wezterm = require("wezterm")
local resurrect = wezterm.plugin.require("https://github.com/StephenGemin/resurrect.wezterm")

config.keys = {
  -- ...
  {
    key = "w",
    mods = "ALT",
    action = resurrect.workspace_state.save_workspace_action(),
  },
  {
    key = "W",
    mods = "ALT",
    action = resurrect.window_state.save_window_action(),
  },
  {
    key = "T",
    mods = "ALT",
    action = resurrect.tab_state.save_tab_action(),
  },
}
```

On the first save of a window or tab you are prompted for a name; subsequent saves are
silent. Saving to a name already in use overwrites the existing file. Once named, a
window or tab is picked up automatically by periodic and event-driven saves.

### Restoring state

Restore workspace, window or tab state via fuzzy finder:

```lua
local resurrect = wezterm.plugin.require("https://github.com/StephenGemin/resurrect.wezterm")

config.keys = {
  -- ...
  {
    key = "r",
    mods = "ALT",
    action = resurrect.fuzzy_loader.restore_action(),
  },
}
```

`restore_action` accepts `restore_opts` to control restore behaviour and an optional
`fuzzy_load_opts` sub-table to customise the picker. For workspace restores,
`current_window = true` (the default) restores in place; set it to `false` to spawn
a new window:

```lua
action = resurrect.fuzzy_loader.restore_action({
  relative        = true,
  restore_text    = true,
  on_pane_restore = resurrect.tab_state.default_on_pane_restore,
  current_window  = true,  -- set false to spawn a new window instead of restoring in place
  -- fuzzy_load_opts = { show_state_with_date = true },
})
```

#### restore_opts

Options accepted by `restore_workspace`, `restore_window`, `restore_tab`, and `restore_action`:

```lua
{
  spawn_in_workspace: boolean?, -- Restores the windows into the saved workspace; default: true. Set false to spawn into the "default" workspace
  switch_workspace: boolean?,   -- Switch the active workspace to the restored one; defaults to the value of spawn_in_workspace
  relative: boolean?,           -- Use relative size when restoring panes
  absolute: boolean?,           -- Use absolute size when restoring panes
  close_open_tabs: boolean?,    -- Closes all tabs which are open in the window, only restored tabs are left
  close_open_panes: boolean?,   -- Closes all panes which are open in the tab, only keeping the panes to be restored
  pane: Pane?,                  -- Restore in this pane
  tab: MuxTab?,                 -- Restore in this tab
  window: MuxWindow,            -- Restore in this window
  resize_window: boolean?,      -- Resizes the window, default: true
  on_pane_restore: fun(pane_tree: pane_tree), -- Function to restore panes; use resurrect.tab_state.default_on_pane_restore
}
```

> [!NOTE]
> `spawn_in_workspace` defaults to `true`: the restored windows are spawned into the
> saved workspace and the active workspace is switched to it. Set
> `spawn_in_workspace = false` to keep the legacy behaviour, where the windows are
> spawned into Wezterm's `"default"` workspace and the active workspace is **not**
> changed — so you stay where you are and the restored windows appear under
> `"default"`. By default `switch_workspace` follows `spawn_in_workspace`; set it
> explicitly to switch (or not) independently of where the windows are spawned.

> [!WARNING]
> The `spawn_in_workspace = true` default is a breaking change from earlier versions,
> which defaulted to `false`. If you relied on restored windows landing in the
> `"default"` workspace, set `spawn_in_workspace = false` to restore the old behaviour.

#### Restoring into the current window

To restore a window state into the current window use `restore_window` with `close_open_tabs`:

```lua
local opts = {
  close_open_tabs = true,
  window = pane:window(),
  on_pane_restore = resurrect.tab_state.default_on_pane_restore,
  relative = true,
  restore_text = true,
}
resurrect.window_state.restore_window(pane:window(), state, opts)
```

This will restore the state into the passed window and additionally close all
the tabs in the window, such that only the restored tabs are visible after restoring.

#### Windows not resizing correctly

Some users has had problems with `window_decorations` and `window_padding`
configuration options, which caused issues when resizing, see [comment](https://github.com/StephenGemin/resurrect.wezterm/issues/72#issuecomment-2582912347).
To avoid this, set `resize_window = false` in your `restore_opts`.

#### Manual dispatch

If you need full control over how each state type is restored, call `fuzzy_load` directly:

```lua
action = wezterm.action_callback(function(win, pane)
  resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id, label)
    local type = string.match(id, "^([^/]+)") -- match before '/'
    id = string.match(id, "([^/]+)$") -- match after '/'
    id = string.match(id, "(.+)%..+$") -- remove file extension
    local opts = {
      relative = true,
      restore_text = true,
      on_pane_restore = resurrect.tab_state.default_on_pane_restore,
    }
    if type == "workspace" then
      local state = resurrect.state_manager.load_state(id, "workspace")
      -- Restores the windows into the saved workspace and switches you to it.
      -- Pass `spawn_in_workspace = false` to spawn into "default" without switching.
      resurrect.workspace_state.restore_workspace(state, opts)
    elseif type == "window" then
      local state = resurrect.state_manager.load_state(id, "window")
      resurrect.window_state.restore_window(pane:window(), state, opts)
    elseif type == "tab" then
      local state = resurrect.state_manager.load_state(id, "tab")
      local new_tab, new_pane = pane:window():spawn_tab({
        cwd = state.pane_tree and state.pane_tree.cwd or nil,
      })
      opts.pane = new_pane
      resurrect.tab_state.restore_tab(new_tab, state, opts)
    end
  end)
end),
```

#### fuzzy_load opts

`resurrect.fuzzy_loader.fuzzy_load(window, pane, callback, opts?)` accepts an optional
`opts` argument to control picker appearance and filtering:

```lua
---@alias fmt_fun fun(label: string): string
---@alias fuzzy_load_opts {
  title: string,               -- dialog title, default: "Load state"
  description: string,         -- description shown above the picker, default: "Select State to Load and press Enter = accept, Esc = cancel, / = filter"
  fuzzy_description: string,   -- description in fuzzy search mode, default: "Search State to Load: "
  is_fuzzy: boolean,           -- enter directly in fuzzy mode, default: true
  ignore_workspaces: boolean,  -- hide workspace entries, default: false
  ignore_tabs: boolean,        -- hide tab entries, default: false
  ignore_windows: boolean,     -- hide window entries, default: false
  fmt_window: fmt_fun,         -- format function for window state name (wezterm.format)
  fmt_workspace: fmt_fun,      -- format function for workspace state name
  fmt_tab: fmt_fun,            -- format function for tab state name
  fmt_date: fmt_fun,           -- format function for date
  show_state_with_date: boolean, -- show last update of the state file, default: false
  date_format: string,         -- date formatting, default: "%d-%m-%Y %H:%M:%S"
  ignore_screen_width: boolean,-- whether to shrink the list if the window is too narrow, default: true
  name_truncature: string,     -- string used when state name is truncated
  min_filename_size: number    -- minimum size of state name before truncation
}
```

### Deleting state

Delete a saved state file via fuzzy finder:

```lua
local resurrect = wezterm.plugin.require("https://github.com/StephenGemin/resurrect.wezterm")

config.keys = {
  -- ...
  {
    key = "d",
    mods = "ALT",
    action = resurrect.fuzzy_loader.delete_action(),
  },
}
```

`delete_action` accepts the same `fuzzy_load_opts` as `fuzzy_load` to customise the picker title, description, etc.

#### Manual dispatch

```lua
action = wezterm.action_callback(function(win, pane)
  resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id)
      resurrect.state_manager.delete_state(id)
    end,
    {
      title = "Delete State",
      description = "Select State to Delete and press Enter = accept, Esc = cancel, / = filter",
      fuzzy_description = "Search State to Delete: ",
      is_fuzzy = true,
    })
end),
```

### Encryption (optional, recommended)

You can optionally configure the plugin to encrypt and decrypt the saved state. [age](https://github.com/FiloSottile/age) is the default encryption provider. [Rage](https://github.com/str4d/rage) and [GnuPG](https://gnupg.org/) encryption are also supported.

#### Install and generate a key

Install `age` and generate a key with:

```sh
$ age-keygen -o key.txt
Public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

> [!NOTE]
> If you prefer to use [GnuPG](https://gnupg.org/), generate a key pair: `gpg --full-generate-key`. Get the public key with `gpg --armor --export your_email@example.com`.
> The private key is your email or key ID associated with the gpg key.

#### Enable encryption in your config

Enable encryption in your Wezterm config:

```lua
local resurrect = wezterm.plugin.require("https://github.com/StephenGemin/resurrect.wezterm")
resurrect.state_manager.set_encryption({
  enable = true,
  method = "age" -- "age" is the default encryption method, but you can also specify "rage" or "gpg"
  private_key = "/path/to/private/key.txt", -- if using "gpg", you can omit this
  public_key = "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p",
})
```

> [!WARNING]
> FOR WINDOWS USERS
>
> Due to Windows limitations with `stdin`, errors cannot be returned from the `encrypt` function.

> [!TIP]
> If the encryption provider is not found in your PATH (common issue for GUI apps on Mac OS), you can specify the absolute path to the executable.
> e.g. `method = "/opt/homebrew/bin/age"`

#### Custom encryption providers

Alternate implementations are possible by providing your own `encrypt` and `decrypt` functions:

```lua
resurrect.state_manager.set_encryption({
  enable = true,
  private_key = "/path/to/private/key.txt",
  public_key = "public_key",
  encrypt = function(file_path, lines)
    -- substitute for your encryption command
    local cmd = string.format(
      "%s -r %s -o %s",
      pub.encryption.method,
      pub.encryption.public_key,
      file_path:gsub(" ", "\\ ")
    )

    local success, output = execute_cmd_with_stdin(cmd, lines)
    if not success then
      error("Encryption failed:" .. output)
    end
  end,
  decrypt = function(file_path)
    -- substitute for your decryption command
    local cmd = { pub.encryption.method, "-d", "-i", pub.encryption.private_key, file_path }

    local success, stdout, stderr = wezterm.run_child_process(cmd)
    if not success then
      error("Decryption failed: " .. stderr)
    end

    return stdout
  end,
})
```

If you wish to share a non-documented way of encrypting your files or think something is missing, then please make a PR or file an issue.

## Configuration

### Configuration reference

**Periodic saving** — `setup()` handles this automatically. For manual control:

```lua
resurrect.state_manager.periodic_save({
  interval_seconds = 900, -- default: 300 when called via setup()
  save_workspaces  = true,
  save_windows     = true,
  save_tabs        = true,
})
```

**Limiting pane output lines**

```lua
resurrect.state_manager.set_max_nlines(1000)
```

Limits each pane to at most `n` lines of saved output. Reduces file size and improves
save/load performance on busy terminals.

**Custom save name**

`resurrect.state_manager.save_state(state, opt_name?)` accepts an optional string to
override the auto-generated filename:

```lua
resurrect.state_manager.save_state(workspace_state.get_workspace_state(), "my-project")
```

### Change the directory to store the saved state

```lua
resurrect.state_manager.change_state_save_dir("/some/other/directory")
```

> [!WARNING]
> FOR WINDOWS USERS
>
> You must ensure that there is write access to the directory where the state is stored,
> as such it is suggested that you set your own state directory like so:
>
> ```lua
> -- Set some directory where Wezterm has write access
> resurrect.state_manager.change_state_save_dir("C:\\Users\\<user>\\Desktop\\state\\")
> ```

### Events

This plugin emits the following events that you can use for your own callback functions:

- `resurrect.error(err)`
- `resurrect.file_io.decrypt.finished(file_path)`
- `resurrect.file_io.decrypt.start(file_path)`
- `resurrect.file_io.encrypt.finished(file_path)`
- `resurrect.file_io.encrypt.start(file_path)`
- `resurrect.file_io.sanitize_json.finished(data)`
- `resurrect.file_io.sanitize_json.start(data)`
- `resurrect.fuzzy_loader.fuzzy_load.finished(window, pane)`
- `resurrect.fuzzy_loader.fuzzy_load.start(window, pane)`
- `resurrect.state_manager.delete_state.finished(file_path)`
- `resurrect.state_manager.delete_state.start(file_path)`
- `resurrect.state_manager.load_state.finished(name, type)`
- `resurrect.state_manager.load_state.start(name, type)`
- `resurrect.state_manager.periodic_save.start(opts)`
- `resurrect.state_manager.periodic_save.finished(opts)`
- `resurrect.file_io.write_state.finished(file_path, event_type)`
- `resurrect.file_io.write_state.start(file_path, event_type)`
- `resurrect.tab_state.restore_tab.finished`
- `resurrect.tab_state.restore_tab.start`
- `resurrect.window_state.restore_window.finished`
- `resurrect.window_state.restore_window.start`
- `resurrect.workspace_state.restore_workspace.finished`
- `resurrect.workspace_state.restore_workspace.start`

Example: sending a toast notification when specified events occur, but suppress on `periodic_save()`:

```lua
local resurrect_event_listeners = {
  "resurrect.error",
  "resurrect.state_manager.save_state.finished",
}
local is_periodic_save = false
wezterm.on("resurrect.periodic_save", function()
  is_periodic_save = true
end)
for _, event in ipairs(resurrect_event_listeners) do
  wezterm.on(event, function(...)
    if event == "resurrect.state_manager.save_state.finished" and is_periodic_save then
      is_periodic_save = false
      return
    end
    local args = { ... }
    local msg = event
    for _, v in ipairs(args) do
      msg = msg .. " " .. tostring(v)
    end
    wezterm.gui.gui_windows()[1]:toast_notification("Wezterm - resurrect", msg, nil, 4000)
  end)
end
```

## State files

State files are json files, which will be decoded into lua tables.
This can be used to create your own layout files which can then be loaded.
Here is an example of a json file:

```json
{
   "window_states":[
      {
         "size":{
            "cols":191,
            "dpi":96,
            "pixel_height":1000,
            "pixel_width":1910,
            "rows":50
         },
         "tabs":[
            {
               "is_active":true,
               "pane_tree":{
                  "cwd":"/home/user/",
                  "domain": "SSHMUX:domain",
                  "height":50,
                  "index":0,
                  "is_active":true,
                  "is_zoomed":false,
                  "left":0,
                  "pixel_height":1000,
                  "pixel_width":1910,
                  "process":"/bin/bash", -- value is empty if attached to a remote domain
                  "text":"Some text", -- not saved if attached to a remote domain, see https://github.com/StephenGemin/resurrect.wezterm/issues/41
                  "top":0,
                  "width":191
               },
               "title":"tab_title"
            }
         ],
         "title":"window_title"
      }
   ],
   "workspace":"workspace_name"
}
```

## Augmenting the command palette

If you would like to add entries in your Wezterm command palette for renaming and switching workspaces:

```lua
local workspace_switcher = wezterm.plugin.require("https://github.com/StephenGemin/smart_workspace_switcher.wezterm")

wezterm.on("augment-command-palette", function(window, pane)
  local workspace_state = resurrect.workspace_state
  return {
    {
      brief = "Window | Workspace: Switch Workspace",
      icon = "md_briefcase_arrow_up_down",
      action = workspace_switcher.switch_workspace(),
    },
    {
      brief = "Window | Workspace: Rename Workspace",
      icon = "md_briefcase_edit",
      action = wezterm.action.PromptInputLine({
        description = "Enter new name for workspace",
        action = wezterm.action_callback(function(window, pane, line)
          if line then
            wezterm.mux.rename_workspace(wezterm.mux.get_active_workspace(), line)
            resurrect.state_manager.save_state(workspace_state.get_workspace_state())
          end
        end),
      }),
    },
  }
end)
```

## FAQ

### Pane CWD is not correct on Windows

If your pane CWD is incorrect then it might be a problem with the shell
integration and OSC 7. See [Wezterm documentation](https://wezfurlong.org/wezterm/shell-integration.html).

### How do I keep my plugins up to date?

#### Manually

Wezterm git clones your plugins into a plugin directory.
Enter `wezterm.plugin.list()` in the Wezterm Debug Overlay (`Ctrl + Shift + L`)
to see where they are stored. You can then update them individually using git pull.

#### Automatically

Add `wezterm.plugin.update_all()` to your Wezterm config.

## Contributions

Suggestions, Issues and PRs are welcome!
The features currently implemented are the ones I use the most, but your
workflow might differ. As such, if you have any proposals on how to improve
the plugin, then please feel free to make an issue or even better a PR!

### Technical details

Restoring of the panes are done via. the `pane_tree` file,
which has functions to work on a binary-like-tree of the panes.
Each node in the pane_tree represents a possible split pane.
If the pane has a `bottom` and/or `right` child, then the pane is split.
If you have any questions to the implementation,
then I suggest you read the code or open an issue and I will try to clarify.
Improvements to this section is also very much welcome.

## Disclaimer

If you don't setup encryption then the state of your terminal is saved as
plaintext json files. Please be aware that the plugin will by default write the
output of the shell among other things, which could contain secrets or other
vulnerable data. If you do not want to store this as plaintext, then please use
the provided documentation for encrypting state.
