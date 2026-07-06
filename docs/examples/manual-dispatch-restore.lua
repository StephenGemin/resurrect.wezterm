-- =============================================================================
-- resurrect.wezterm -- manual dispatch of fuzzy_load, handling workspace,
-- window, and tab restores explicitly instead of using restore_action().
-- Bound to ALT-r.
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
		key = 'r',
		mods = 'ALT',
		action = wezterm.action_callback(function(win, pane)
			resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id)
				local state_type = id:match('^([^/]+)') -- "workspace" | "window" | "tab"
				local name = id:match('([^/]+)$'):match('(.+)%..+$') -- strip dir + ".json"
				local opts = {
					relative = true,
					restore_text = true,
					on_pane_restore = resurrect.pane_tree.default_on_pane_restore,
				}
				if state_type == 'workspace' then
					-- Restores the windows into the saved workspace and switches you to it.
					-- Pass `spawn_in_workspace = false` to spawn into "default" without switching.
					resurrect.workspace_state.restore_workspace(resurrect.state_manager.load_state(name, 'workspace'), opts)
				elseif state_type == 'window' then
					resurrect.window_state.restore_window(pane:window(), resurrect.state_manager.load_state(name, 'window'), opts)
				elseif state_type == 'tab' then
					local state = resurrect.state_manager.load_state(name, 'tab')
					local new_tab, new_pane = pane:window():spawn_tab({
						cwd = state.pane_tree and state.pane_tree.cwd or nil,
					})
					opts.pane = new_pane
					resurrect.tab_state.restore_tab(new_tab, state, opts)
				end
			end)
		end),
	},
}

return M
