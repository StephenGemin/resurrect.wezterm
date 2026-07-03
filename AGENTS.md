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
  init.lua                   entry point; loads modules, sets state directory, exports setup()
  types.lua                  Lua type aliases (tab_size, workspace_state, restore_opts …)
  resurrect/
    state_manager.lua        save/load/delete state, periodic auto-save, startup restore
    file_io.lua              raw file read/write, JSON serialisation, encryption dispatch
    encryption.lua           age / rage / gpg encrypt + decrypt, platform-aware stdin
    workspace_state.lua      get_workspace_state(), restore_workspace()
    window_state.lua         get_window_state(), restore_window(), save_window_action()
    tab_state.lua            get_tab_state(), restore_tab(), save_tab_action()
    pane_tree.lua            binary-tree representation of pane splits; fold/map
    restore_baseline.lua     per-pane replayed-text registry + OSC 133 idle check,
                             so saves don't re-capture (and grow) idle restored panes
    utils.lua                platform detection, string helpers, ensure_folder_exists
    fuzzy_loader.lua         fuzzy-finder UI for picking a saved state to load
    test/
      text.lua               manual test helper — injects chars to exercise encoding
spec/
  spec_helper.lua            shared wezterm mock and module loader for busted specs
  unit/                      unit tests (busted --run=unit)
  integration/               integration tests; require lunajson (busted --run=integration)
scripts/
  migrate-from-mlflexer.sh   copies old MLFlexer state files into this fork's default dir
                             (macOS, Linux, Windows via Git Bash)
README.md
AGENTS.md                    (this file)
CLAUDE.md                    AI assistant guidance
.busted                      busted named configs: unit, integration, default (= unit)
.luarc.json                  Lua LSP config (Lua 5.4, wezterm globals)
.github/workflows/ci.yml     stylua + luacheck + lua-language-server + unit + integration
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

# Unit tests (CI runs these on every PR; needs Lua 5.4 + busted)
busted --run=unit               # spec/unit/ only
busted --run=integration        # spec/integration/ only (also needs lunajson)
busted                          # default: same as --run=unit

# Manual smoke test inside Wezterm
# Add the plugin to your wezterm.lua, then use the save/load keybindings
# described in README.md and verify state round-trips correctly.
```

CI (`.github/workflows/ci.yml`) has three jobs that must stay green on every PR:

- `lint` — stylua, luacheck, and lua-ls over `plugin/`.
- `test` — the busted unit suite (`spec/unit/`).
- `integration` — the busted integration suite (`spec/integration/`); installs lunajson.

### Unit tests (`spec/unit/`)

The suite targets the **user-facing contract documented in README.md** — the public
API names a user's `wezterm.lua` calls, and the documented default behaviours — so a
refactor that silently breaks a user's config fails CI instead. It is deliberately
small and behaviour-focused, not a coverage exercise.

**Test philosophy — behaviour over mechanism.** A test should assert what a user
observes, not how the code achieves it. Avoid tests that:
- Inspect internal action objects, stub module-level functions, or assert on which
  private helper was called.
- Would need to be rewritten whenever an implementation detail changes but the
  observable outcome stays the same.

If writing a test requires stubbing an internal function to make it compile, that is
a sign the test is asserting a mechanism. Prefer not to write it.

The plugin modules `require("wezterm")` and reach into `wezterm.mux` / `gui` at load
time, so they cannot be required directly under plain Lua. `spec/spec_helper.lua`
installs a controllable `wezterm` mock and (re)loads a module against it; specs assert
on recorded side effects (emitted events, mux/timer calls). When you add a module that
touches a new `wezterm.*` field, extend the mock in `spec/spec_helper.lua`.

Current unit specs:

- `api_surface_spec.lua` — every `resurrect.*` function the README references exists,
  and `init.lua` exports the submodules under the documented names.
- `save_state_spec.lua` — state-shape → file type / path routing and `opt_name`.
- `load_state_spec.lua` — returns the parsed table, or `{}` (never nil) on a bad file.
- `restore_workspace_spec.lua` — the `spawn_in_workspace` / `switch_workspace` default
  matrix flagged as a breaking change in README.
- `periodic_save_spec.lua` — the documented 15-minute default; workspace always saves;
  windows/tabs only save when `user_named = true` is present in their state file.

Run a single file with `busted spec/unit/save_state_spec.lua`.

### Integration tests (`spec/integration/`)

These load `init.lua` the same way WezTerm does (real `require` chain, real tmpdir)
and exercise the full save → load pipeline against actual filesystem I/O. They require
`lunajson` (`luarocks install lunajson`).

Current integration specs:

- `setup_spec.lua` — `resurrect.setup(config)` completes without error and wires
  keybindings, gui-startup, and periodic_save correctly.
- `round_trip_spec.lua` — workspace state survives a full save → load cycle with real
  JSON encoding and real files on disk.

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
