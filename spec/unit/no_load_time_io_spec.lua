-- Regression guard for the "attempt to yield across a C-call boundary" crash.
--
-- wezterm.run_child_process is async (coroutine-based). Calling it while
-- inside a C-call frame -- which is what require() runs in -- raises:
--   "attempt to yield across a C-call boundary"
-- and prevents the plugin from loading at all.
--
-- The invariant enforced here:
--   1. require("resurrect.state_manager") must not call run_child_process.
--   2. change_state_save_dir() must not call run_child_process.
--   3. save_state() MUST call ensure_folder_exists (deferred to event-handler
--      time, where coroutine yielding is allowed).
--
-- If any of these break, the plugin will crash on startup for every user.

local helper = require("spec_helper")

-- Load state_manager with a run_child_process stub that raises an error
-- identical in spirit to the real WezTerm C-frame failure. Any code path
-- that touches it at the wrong time will surface immediately as a test error.
local function load_with_failing_rcp()
	local wz = helper.new_wezterm({
		patch = function(w, _)
			w.run_child_process = function()
				error("run_child_process called in a C-call frame: would crash wezterm")
			end
		end,
	})
	return helper.load("resurrect.state_manager", wz)
end

describe("state_manager: no async I/O at require-time or in change_state_save_dir", function()
	it("does not call run_child_process when the module is required", function()
		assert.has_no_error(function()
			load_with_failing_rcp()
		end)
	end)

	it("does not call run_child_process when change_state_save_dir is called", function()
		local sm = load_with_failing_rcp()
		assert.has_no_error(function()
			sm.change_state_save_dir("/some/state/dir/")
		end)
	end)

	it("save_state calls ensure_folder_exists for the correct type subdirectory (lazy, event-time)", function()
		local wz = helper.new_wezterm()
		local sm = helper.load("resurrect.state_manager", wz)
		sm.change_state_save_dir("/states/")

		local utils = require("resurrect.utils")
		local ensure_calls = {}
		utils.ensure_folder_exists = function(path)
			table.insert(ensure_calls, path)
			return true
		end

		local file_io = require("resurrect.file_io")
		file_io.write_state = function() end

		sm.save_state({ workspace = "test", window_states = {} })
		assert.are.equal(1, #ensure_calls)
		assert.are.equal("/states/workspace", ensure_calls[1])
	end)

	it("save_state calls ensure_folder_exists for window type", function()
		local wz = helper.new_wezterm()
		local sm = helper.load("resurrect.state_manager", wz)
		sm.change_state_save_dir("/states/")

		local utils = require("resurrect.utils")
		local ensure_calls = {}
		utils.ensure_folder_exists = function(path)
			table.insert(ensure_calls, path)
			return true
		end

		local file_io = require("resurrect.file_io")
		file_io.write_state = function() end

		sm.save_state({ title = "mywin", tabs = {} })
		assert.are.equal(1, #ensure_calls)
		assert.are.equal("/states/window", ensure_calls[1])
	end)

	it("save_state calls ensure_folder_exists for tab type", function()
		local wz = helper.new_wezterm()
		local sm = helper.load("resurrect.state_manager", wz)
		sm.change_state_save_dir("/states/")

		local utils = require("resurrect.utils")
		local ensure_calls = {}
		utils.ensure_folder_exists = function(path)
			table.insert(ensure_calls, path)
			return true
		end

		local file_io = require("resurrect.file_io")
		file_io.write_state = function() end

		sm.save_state({ title = "mytab", pane_tree = {} })
		assert.are.equal(1, #ensure_calls)
		assert.are.equal("/states/tab", ensure_calls[1])
	end)
end)
