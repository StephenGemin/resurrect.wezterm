-- =============================================================================
-- resurrect.wezterm -- configure the safe-restore process allowlist by calling
-- pane_tree's functions directly, as an alternative to setup()'s
-- `safe_restore_processes` option.
--
-- Drop this in as its own module (e.g. resurrect_plugin.lua) and from your
-- wezterm.lua: local resurrect_plugin = require('resurrect_plugin')
--              resurrect_plugin.setup(config)
-- =============================================================================

local wezterm = require('wezterm')

local PLUGIN_URL = 'https://github.com/StephenGemin/resurrect.wezterm'

-- setup is a no-op default so callers can always invoke M.setup(config) safely
-- even if the plugin fails to load (pcall below returns early in that case).
local M = { setup = function() end }

local ok, resurrect = pcall(wezterm.plugin.require, PLUGIN_URL)
if not ok then
	wezterm.log_warn('resurrect.wezterm failed to load: ' .. tostring(resurrect))
	return M
end

function M.setup(config)
	resurrect.setup(config, {
		periodic_interval = 300,
	})

	-- Extend the built-in allowlist:
	resurrect.pane_tree.add_safe_restore_processes({ 'lazygit', 'k9s' })

	-- ...or fully replace it (pass {} to disable process relaunch entirely):
	-- resurrect.pane_tree.set_safe_restore_processes({ 'vim', 'nvim' })
end

return M
