-- Minimal WezTerm config for the E2E smoke test.
-- Loads the plugin from the local repo path and calls setup(), then writes a
-- sentinel file when gui-startup fires. smoke.sh polls for that file to confirm
-- the plugin loaded and started without error.
--
-- Run via: RESURRECT_REPO_PATH=<abs-path> RESURRECT_SENTINEL=<file> \
--          wezterm --config-file spec/e2e/smoke_wezterm.lua start

local wezterm = require("wezterm")
local sep = package.config:sub(1, 1)
local repo_path = os.getenv("RESURRECT_REPO_PATH") or "."

-- Add plugin submodules to the path before loading init.lua.
-- Mirrors what wezterm.plugin.require() does internally: it adds
-- <plugin_dir>/plugin/?.lua to package.path so submodule requires work.
-- init.lua's wezterm.plugin.list() loop won't find this plugin (not registered
-- via a URL), but since package.path is already set here, the requires succeed.
package.path = repo_path .. sep .. "plugin" .. sep .. "?.lua;" .. package.path

-- Load the plugin entry point directly, the same way wezterm.plugin.require does.
local resurrect = dofile(repo_path .. sep .. "plugin" .. sep .. "init.lua")

local config = wezterm.config_builder()
resurrect.Setup(config)

-- Our handler fires after the plugin's gui-startup handler (registered by setup()).
-- Writing the sentinel here proves: config loaded, setup() ran, gui-startup fired —
-- all without a Lua error halting execution.
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
