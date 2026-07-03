-- WezTerm config for the E2E save verification test.
-- Loads the plugin and saves workspace state twice, checking each lands on
-- disk before writing the sentinel:
--   1. To the real platform_default_state_dir(), before any override --
--      the only place is_windows/is_mac get exercised against wezterm's
--      actual target_triple on real Windows/macOS/Linux hardware. The
--      expected path here is computed independently of
--      plugin/resurrect/utils.lua so a bug in the plugin's own platform
--      detection can't also corrupt the expectation.
--   2. To a repo-local scratch dir via change_state_save_dir(), covering
--      the override path fuzzy_loader/state_manager callers rely on.
--
-- Run via: RESURRECT_REPO_PATH=<abs-path> RESURRECT_SENTINEL=<file> \
--          wezterm --config-file spec/e2e/wezterm_save.lua start

local wezterm = require("wezterm")
local sep = package.config:sub(1, 1)
local repo_path = os.getenv("RESURRECT_REPO_PATH") or "."

package.path = repo_path .. sep .. "plugin" .. sep .. "?.lua;" .. package.path
local resurrect = dofile(repo_path .. sep .. "plugin" .. sep .. "init.lua")

local config = wezterm.config_builder()

local function expected_default_dir()
	local runner_os = os.getenv("RUNNER_OS")
	local is_windows = runner_os == "Windows" or (not runner_os and wezterm.target_triple:find("windows"))
	local is_mac = runner_os == "macOS" or (not runner_os and wezterm.target_triple:find("darwin"))

	if is_windows then
		local appdata = os.getenv("APPDATA") or (wezterm.home_dir .. "\\AppData\\Roaming")
		return appdata .. "\\wezterm\\resurrect\\"
	elseif is_mac then
		return wezterm.home_dir .. "/Library/Application Support/wezterm/resurrect/"
	else
		local xdg = os.getenv("XDG_STATE_HOME") or (wezterm.home_dir .. "/.local/state")
		return xdg .. "/wezterm/resurrect/"
	end
end

-- Save to save_dir, verify the expected file exists, and clean up exactly
-- what was created. Returns nil on success or a "fail: ..." message.
local function save_and_check(save_dir)
	local ws_state = resurrect.workspace_state.get_workspace_state()
	resurrect.state_manager.save_state(ws_state, "e2e-test")

	local expected = save_dir .. "workspace" .. sep .. "e2e-test.json"
	local f = io.open(expected, "r")
	local failure = nil
	if f then
		f:close()
	else
		failure = "fail: missing " .. expected
	end

	-- Clean up only what this test created, leaving the rest of the real
	-- resurrect/ directory (if anything else lives there) untouched.
	os.remove(expected)
	os.remove(save_dir .. "workspace")

	return failure
end

wezterm.on("gui-startup", function()
	local result = save_and_check(expected_default_dir())

	if not result then
		local scratch_dir = repo_path .. sep .. ".resurrect_e2e_state" .. sep
		resurrect.state_manager.change_state_save_dir(scratch_dir)
		result = save_and_check(scratch_dir)
	end

	local sentinel = os.getenv("RESURRECT_SENTINEL")
	if sentinel then
		local sf = io.open(sentinel, "w")
		if sf then
			sf:write(result or "ok")
			sf:close()
		end
	end
end)

return config
