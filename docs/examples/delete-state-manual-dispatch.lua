-- =============================================================================
-- resurrect.wezterm -- manual dispatch of fuzzy_load for deleting saved state,
-- with a custom picker title/description instead of using delete_action().
-- Bound to ALT-d.
--
-- Drop this in as its own module (e.g. resurrect_plugin.lua) and from your
-- wezterm.lua: local resurrect_plugin = require('resurrect_plugin')
--              resurrect_plugin.setup(config)
--              -- merge resurrect_plugin.keys into config.keys
-- =============================================================================

local wezterm = require('wezterm')

local PLUGIN_URL = 'https://github.com/StephenGemin/resurrect.wezterm'

-- setup is a no-op default so callers can always invoke M.setup(config) safely
-- even if the plugin fails to load (pcall below returns early in that case).
local M = { keys = {}, setup = function() end }

local ok, resurrect = pcall(wezterm.plugin.require, PLUGIN_URL)
if not ok then
	wezterm.log_warn('resurrect.wezterm failed to load: ' .. tostring(resurrect))
	return M
end

function M.setup(config)
	resurrect.setup(config, {
		periodic_interval = 300,
	})
end

M.keys = {
	{
		key = 'd',
		mods = 'ALT',
		action = wezterm.action_callback(function(win, pane)
			resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id)
				resurrect.state_manager.delete_state(id)
			end, {
				title = 'Delete State',
				description = 'Select State to Delete and press Enter = accept, Esc = cancel, / = filter',
				fuzzy_description = 'Search State to Delete: ',
				is_fuzzy = true,
			})
		end),
	},
}

return M
