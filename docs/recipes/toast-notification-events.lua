-- =============================================================================
-- resurrect.wezterm -- send a toast notification on selected plugin events,
-- suppressing the noisy write-finished event fired by periodic_save().
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

	local resurrect_event_listeners = {
		'resurrect.error',
		'resurrect.file_io.write_state.finished',
	}
	local is_periodic_save = false
	wezterm.on('resurrect.state_manager.periodic_save.start', function()
		is_periodic_save = true
	end)
	for _, event in ipairs(resurrect_event_listeners) do
		wezterm.on(event, function(...)
			if event == 'resurrect.file_io.write_state.finished' and is_periodic_save then
				is_periodic_save = false
				return
			end
			local args = { ... }
			local msg = event
			for _, v in ipairs(args) do
				msg = msg .. ' ' .. tostring(v)
			end
			wezterm.gui.gui_windows()[1]:toast_notification('Wezterm - resurrect', msg, nil, 4000)
		end)
	end
end

return M
