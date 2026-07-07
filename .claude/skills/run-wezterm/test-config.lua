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

return config
