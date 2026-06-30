-- Advanced E2E smoke config: exercises the full setup() options path.
-- Explicitly passes every documented opt so that keybindings (config.keys),
-- status_bar (update-right-status event), and all save flags are wired up.
-- Catches regressions that the basic config misses because it uses defaults.
--
-- Run via: RESURRECT_REPO_PATH=<abs-path> RESURRECT_SENTINEL=<file> \
--          wezterm --config-file spec/e2e/wezterm_advanced.lua start

local wezterm = require("wezterm")
local sep = package.config:sub(1, 1)
local repo_path = os.getenv("RESURRECT_REPO_PATH") or "."

package.path = repo_path .. sep .. "plugin" .. sep .. "?.lua;" .. package.path

local resurrect = dofile(repo_path .. sep .. "plugin" .. sep .. "init.lua")

local config = wezterm.config_builder()

resurrect.setup(config, {
	periodic_interval = 300,
	restore_delay = 0,
	save_workspaces = true,
	save_windows = true,
	save_tabs = true,
	keybindings = true,
	status_bar = true,
})

wezterm.on("gui-startup", function()
	local sentinel = os.getenv("RESURRECT_SENTINEL")
	if sentinel then
		local f = io.open(sentinel, "w")
		if f then
			f:write("ok")
			f:close()
		end
	end
end)

return config
