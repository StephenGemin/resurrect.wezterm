-- =============================================================================
-- resurrect.wezterm -- restore a saved window state into the *current* window
-- instead of spawning a new one, closing the window's other tabs so only the
-- restored tabs remain. Bound to ALT-w.
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
		key = 'w',
		mods = 'ALT',
		action = wezterm.action_callback(function(win, pane)
			resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id)
				local state_type = id:match('^([^/]+)') -- "workspace" | "window" | "tab"
				local name = id:match('([^/]+)$'):match('(.+)%..+$') -- strip dir + ".json"
				if state_type ~= 'window' then
					return
				end
				local state = resurrect.state_manager.load_state(name, 'window')
				resurrect.window_state.restore_window(pane:window(), state, {
					close_open_tabs = true, -- close this window's other tabs; only the restored ones remain
					window = pane:window(),
					on_pane_restore = resurrect.pane_tree.default_on_pane_restore,
					relative = true,
					restore_text = true,
				})
			end, { ignore_workspaces = true, ignore_tabs = true }) -- only offer window states
		end),
	},
}

return M
