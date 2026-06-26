# resurrect.wezterm

A Lua plugin for [Wezterm](https://wezfurlong.org/wezterm/) that saves and restores
terminal session state: workspaces, windows, tabs, panes, scrollback, and foreground
processes. Inspired by `tmux-resurrect` and `tmux-continuum`.

## Project goals

- Save and restore full Wezterm session layout without external dependencies.
- Cross-platform: Windows, macOS, and Linux from a single Lua codebase.
- Optional encryption at rest via `age`, `rage`, or `gpg`.
- Minimal surface area — the plugin exposes a small public API and does one thing well.

## Project structure

```
plugin/
  init.lua                   entry point; loads modules, sets state directory
  types.lua                  Lua type aliases (tab_size, workspace_state, restore_opts …)
  resurrect/
    state_manager.lua        save/load/delete state, periodic auto-save, startup restore
    file_io.lua              raw file read/write, JSON serialisation, encryption dispatch
    encryption.lua           age / rage / gpg encrypt + decrypt, platform-aware stdin
    workspace_state.lua      get_workspace_state(), restore_workspace()
    window_state.lua         get_window_state(), restore_window(), save_window_action()
    tab_state.lua            get_tab_state(), restore_tab(), save_tab_action()
    pane_tree.lua            binary-tree representation of pane splits; fold/map
    utils.lua                platform detection, string helpers, ensure_folder_exists
    fuzzy_loader.lua         fuzzy-finder UI for picking a saved state to load
    test/
      text.lua               manual test helper — injects chars to exercise encoding
README.md
AGENTS.md                    (this file)
CLAUDE.md                    AI assistant guidance
.luarc.json                  Lua LSP config (Lua 5.4, wezterm globals)
.github/workflows/ci.yml     stylua + luacheck + lua-language-server on PRs
```

State files are saved outside the repo (default: `$XDG_DATA_HOME/wezterm/resurrect/`
or platform equivalent), not committed.

## Reading this repo efficiently

Use the structure map above to go straight to the relevant file.  Do not read the
entire plugin directory on every task — most changes touch one or two files.  Read only:

1. The file you are changing, plus any file it directly `require()`s.
2. `types.lua` when the change involves the public state shape.
3. Additional files only when those leave you without enough context to act.

Stop reading once you can act.

## Build and test

There is no build step — Wezterm loads the plugin directly.

```sh
# Static analysis (CI runs these on every PR)
stylua --check plugin/          # formatting
luacheck plugin/                # linting
lua-language-server --check plugin/ --logpath /tmp/lua-ls-log  # type / nil checks

# Manual smoke test inside Wezterm
# Add the plugin to your wezterm.lua, then use the save/load keybindings
# described in README.md and verify state round-trips correctly.
```

CI (`.github/workflows/ci.yml`) must stay green: stylua, luacheck, and lua-ls run on
every PR and on every push to an open PR.

## Code style

- Lua 5.4; target the Wezterm embedded interpreter.
- `stylua` is authoritative for formatting — do not hand-format.
- `luacheck` must report zero warnings; justify any `-- luacheck: disable` inline.
- Public functions live in a `pub` table returned at the end of each module.
- Keep modules single-purpose; cross-module calls go through `require`, not globals.
- Guard optional `opts` parameters with a nil check at the top of the function.
- Prefer `wezterm.run_child_process()` with an args array over `os.execute()` with
  string concatenation — avoids shell injection.

## What requires a conversation first

- Changing the saved state JSON schema (breaks all existing saves — needs migration).
- Adding a new encryption backend.
- Changing the public API surface (`pub.*` exports used in user configs).
- Dropping support for a platform (Windows, macOS, Linux).
- Adding an external runtime dependency.
- Any broad refactor spanning more than two modules.

## What to avoid

- `os.execute()` with concatenated strings — use `wezterm.run_child_process()`.
- Unguarded access to `opts` fields when `opts` may be nil.
- Writing to or reading from paths outside the configured state directory.
- Relying on `io.popen` for large payloads — it silently truncates or fails.
- Dead exports: if a public function is removed from all call sites, remove the export.
- Hardcoding platform separators — use `utils.separator`.
