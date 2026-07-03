-- WezTerm config for the E2E default-save-directory verification test.
-- Unlike wezterm_save.lua, this does NOT call change_state_save_dir(), so
-- save_state() writes to the real platform_default_state_dir() location.
-- This is the only test that exercises is_windows/is_mac against wezterm's
-- actual target_triple on real Windows/macOS/Linux hardware -- a plugin
-- bug in that detection (e.g. a substring-matching typo) silently picks the
-- wrong directory with no loud failure, so this must be checked for real
-- rather than mocked.
--
-- Run via: RESURRECT_REPO_PATH=<abs-path> RESURRECT_SENTINEL=<file> \
--          wezterm --config-file spec/e2e/wezterm_save_default_dir.lua start

local wezterm = require("wezterm")
local sep = package.config:sub(1, 1)
local repo_path = os.getenv("RESURRECT_REPO_PATH") or "."

package.path = repo_path .. sep .. "plugin" .. sep .. "?.lua;" .. package.path
local resurrect = dofile(repo_path .. sep .. "plugin" .. sep .. "init.lua")

local config = wezterm.config_builder()

-- Computed independently of plugin/resurrect/utils.lua so a bug in the
-- plugin's own platform detection can't also corrupt the expectation here.
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

wezterm.on("gui-startup", function()
	local save_dir = expected_default_dir()

	local ws_state = resurrect.workspace_state.get_workspace_state()
	resurrect.state_manager.save_state(ws_state, "e2e-test")

	local expected = save_dir .. "workspace" .. sep .. "e2e-test.json"
	local f = io.open(expected, "r")
	local result = f and "ok" or ("fail: missing " .. expected)
	if f then
		f:close()
	end

	-- Clean up only what this test created, leaving the rest of the real
	-- resurrect/ directory (if anything else lives there) untouched.
	os.remove(expected)
	os.remove(save_dir .. "workspace")

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
