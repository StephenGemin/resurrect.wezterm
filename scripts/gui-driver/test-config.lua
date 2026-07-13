-- Isolated wezterm config for live-debugging resurrect.wezterm.
--
-- Used by drive.sh via `wezterm --config-file`. It exists so the throwaway test
-- instance NEVER touches the user's real saved state: change_state_save_dir()
-- redirects every save/restore to the scratch dir passed in
-- RESURRECT_TEST_STATE_DIR. Do not point that env var at a real resurrect dir.
--
-- The plugin is loaded from the wezterm plugin cache, so whatever drive.sh
-- copied into that cache (uncommitted plugin/ changes) is what runs here.

local wezterm = require("wezterm")
local config = wezterm.config_builder()

config.check_for_updates = false

local resurrect = wezterm.plugin.require("https://github.com/StephenGemin/resurrect.wezterm")

local state_dir = os.getenv("RESURRECT_TEST_STATE_DIR")
if not state_dir or state_dir == "" then
	-- Refuse to run against the default (real) state dir.
	error("RESURRECT_TEST_STATE_DIR must be set to a scratch directory")
end
resurrect.state_manager.change_state_save_dir(state_dir)

-- periodic_interval short so a save re-captures pane text a few seconds after
-- the structural event_driven_save fires (that first save can land before the
-- shell has echoed your markers). keybindings off: this instance is driven by
-- `wezterm cli`, not by hand.
resurrect.setup(config, {
	periodic_interval = 10,
	keybindings = false,
})

-- Test-only dispatch hook so a headless driver can invoke the plugin's REAL
-- restore/delete code paths without the fuzzy picker (wezterm cli can't navigate
-- an InputSelector). `drive.sh restore <ws>` / `delete <ws>` make the shell emit
-- an OSC SetUserVar, which fires user-var-changed. This calls the SAME public API
-- fuzzy_loader.restore_action / delete_action call — it bypasses the picker UI, it
-- does NOT ship in the plugin. See README.md "Driving the picker flows".
wezterm.on("user-var-changed", function(_window, _pane, name, value)
	if name == "resurrect_test_restore" then
		-- Mirror restore_action's workspace restorer: no window in opts, so
		-- restore_workspace spawns fresh windows for the whole saved state.
		resurrect.workspace_state.restore_workspace(
			resurrect.state_manager.load_state(value, "workspace"),
			{
				relative = true,
				restore_text = true,
				on_pane_restore = resurrect.tab_state.default_on_pane_restore,
			}
		)
	elseif name == "resurrect_test_delete" then
		-- delete_state wants a path RELATIVE to the save dir (it prepends the dir
		-- and rejects absolute paths); mirror what delete_action passes as `id`.
		resurrect.state_manager.delete_state("workspace/" .. value .. ".json")
	end
end)

return config
