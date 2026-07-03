-- WezTerm config for the E2E save verification test.
-- Loads the plugin, saves workspace state to a temp directory, then checks
-- that the expected file exists on disk before writing the sentinel.
--
-- Run via: RESURRECT_REPO_PATH=<abs-path> RESURRECT_SENTINEL=<file> \
--          wezterm --config-file spec/e2e/wezterm_save.lua start

local wezterm = require("wezterm")
local sep = package.config:sub(1, 1)
local repo_path = os.getenv("RESURRECT_REPO_PATH") or "."

package.path = repo_path .. sep .. "plugin" .. sep .. "?.lua;" .. package.path
local resurrect = dofile(repo_path .. sep .. "plugin" .. sep .. "init.lua")

local config = wezterm.config_builder()

wezterm.on("gui-startup", function()
	local save_dir = repo_path .. sep .. ".resurrect_e2e_state" .. sep
	resurrect.state_manager.change_state_save_dir(save_dir)

	local ws_state = resurrect.workspace_state.get_workspace_state()
	resurrect.state_manager.save_state(ws_state, "e2e-test")

	local expected = save_dir .. "workspace" .. sep .. "e2e-test.json"
	local f = io.open(expected, "r")
	local result = f and "ok" or ("fail: missing " .. expected)
	if f then
		f:close()
	end

	local sentinel = os.getenv("RESURRECT_SENTINEL")
	if sentinel then
		local sf = io.open(sentinel, "w")
		if sf then
			sf:write(result)
			sf:close()
		end
	end
end)

return config
