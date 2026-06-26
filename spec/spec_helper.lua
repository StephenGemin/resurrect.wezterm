-- Shared test harness for the busted unit-test suite.
--
-- The plugin modules all `require("wezterm")` and reach into `wezterm.mux`,
-- `wezterm.gui`, etc. at load time, so they cannot be required directly under a
-- plain Lua interpreter. This helper installs a controllable `wezterm` mock and
-- (re)loads a plugin module against it, so tests can exercise the real code with
-- the wezterm side effects observable.

local M = {}

-- Make sure the plugin and spec trees are importable even when busted is invoked
-- without the repo `.busted` config (e.g. `busted spec/save_state_spec.lua`).
local function ensure_path(entry)
	if not package.path:find(entry, 1, true) then
		package.path = entry .. ";" .. package.path
	end
end
ensure_path("./plugin/?.lua")
ensure_path("./spec/?.lua")

-- Forget every cached plugin module (and the wezterm mock) so the next require
-- re-runs the module body against a fresh mock. Without this, module-level state
-- such as `file_io.encryption` or `state_manager.save_state_dir` would leak
-- between tests.
local function reset_loaded()
	for name in pairs(package.loaded) do
		if name == "wezterm" or name == "init" or name:match("^resurrect") or name:match("^helpers%.") then
			package.loaded[name] = nil
		end
	end
end

-- Build a fresh wezterm mock. `o` tweaks specific behaviours; `rec` records the
-- side effects (emitted events and mux/time calls) so tests can assert on them.
---@param o table?
---@return table wezterm, table rec
function M.new_wezterm(o)
	o = o or {}
	local rec = { emits = {}, calls = {} }

	local wz = { _rec = rec }
	wz.target_triple = o.target_triple or "x86_64-unknown-linux-gnu"
	wz.nerdfonts = setmetatable({}, {
		__index = function()
			return ""
		end,
	})

	function wz.emit(event, ...)
		table.insert(rec.emits, { event = event, args = { ... } })
	end
	function wz.log_error() end
	function wz.log_warn() end
	function wz.log_info() end
	function wz.format()
		return ""
	end
	function wz.shell_join_args(args)
		return table.concat(args or {}, " ")
	end
	function wz.run_child_process()
		return true, "", ""
	end
	-- In wezterm an action callback returns an opaque action; for tests we keep
	-- the raw function so callbacks can be invoked directly.
	function wz.action_callback(fn)
		return fn
	end
	wz.action = setmetatable({}, {
		__index = function(_, key)
			return function(arg)
				return { __action = key, arg = arg }
			end
		end,
	})
	-- JSON is only exercised by tests that stub file_io, so trivial stubs suffice.
	function wz.json_encode()
		return "{}"
	end
	function wz.json_parse()
		return {}
	end

	wz.time = {
		call_after = function(seconds, fn)
			table.insert(rec.calls, { name = "call_after", seconds = seconds, fn = fn })
		end,
	}

	wz.gui = {
		gui_windows = function()
			return o.gui_windows or {}
		end,
	}

	wz.plugin = {
		require = function(url)
			if o.plugin_require then
				return o.plugin_require(url)
			end
			return {}
		end,
	}

	wz.mux = {
		set_active_workspace = function(ws)
			table.insert(rec.calls, { name = "set_active_workspace", workspace = ws })
		end,
		get_active_workspace = function()
			return o.active_workspace or "default"
		end,
		rename_workspace = function(from, to)
			table.insert(rec.calls, { name = "rename_workspace", from = from, to = to })
		end,
		all_windows = function()
			return o.all_windows or {}
		end,
		spawn_window = function(args)
			table.insert(rec.calls, { name = "spawn_window", args = args })
			local result = o.spawn_window_result or {}
			return result.tab, result.pane, result.window
		end,
		get_domain = function()
			return {
				is_spawnable = function()
					return true
				end,
			}
		end,
	}

	if o.patch then
		o.patch(wz, rec)
	end

	return wz, rec
end

-- Load a plugin module fresh against the given wezterm mock.
---@param modname string e.g. "resurrect.state_manager"
---@param wz table the mock returned by M.new_wezterm
---@return table module
function M.load(modname, wz)
	reset_loaded()
	package.preload["wezterm"] = function()
		return wz
	end
	return require(modname)
end

-- Find the first recorded mux/time call with the given name.
---@return table?
function M.find_call(rec, name)
	for _, call in ipairs(rec.calls) do
		if call.name == name then
			return call
		end
	end
	return nil
end

-- Find the first emitted event with the given name.
---@return table?
function M.find_emit(rec, event)
	for _, e in ipairs(rec.emits) do
		if e.event == event then
			return e
		end
	end
	return nil
end

return M
