-- =============================================================================
-- resurrect.wezterm -- restore into the current workspace without switching
-- (the MLFlexer-equivalent behavior), bound to LEADER-R.
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
		key = 'R',
		mods = 'LEADER',
		action = wezterm.action_callback(function(win, pane)
			resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id)
				local state_type = id:match('^([^/]+)') -- "workspace" | "window" | "tab"
				local name = id:match('([^/]+)$'):match('(.+)%..+$') -- strip dir + ".json"
				if state_type == 'workspace' then
					resurrect.workspace_state.restore_workspace(resurrect.state_manager.load_state(name, 'workspace'), {
						relative = true,
						restore_text = true,
						on_pane_restore = resurrect.tab_state.default_on_pane_restore,
						spawn_in_workspace = false, -- MLFlexer-equivalent: stay in the current workspace
						switch_workspace = false,
					})
				end
			end)
		end),
	},
}

return M
