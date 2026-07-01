-- periodic_save is the headline "save my session every 15 minutes" feature from
-- the README. These tests pin the documented default interval and that the
-- scheduled callback actually saves a workspace, without waiting on a real timer.

local helper = require("spec_helper")

describe("state_manager.periodic_save", function()
	local state_manager, rec, saved, wz

	before_each(function()
		wz, rec = helper.new_wezterm()
		state_manager = helper.load("resurrect.state_manager", wz)

		-- Observe save_state without touching disk, and short-circuit the workspace
		-- snapshot (which would need a full mux mock).
		saved = {}
		state_manager.save_state = function(state)
			table.insert(saved, state)
		end
		-- Default: no entity is user-named (hermetic; avoids real filesystem reads).
		state_manager.is_user_named = function()
			return false
		end
		require("resurrect.workspace_state").get_workspace_state = function()
			return { workspace = "snapshot", window_states = {} }
		end
	end)

	it("defaults to a 15 minute (900s) interval", function()
		state_manager.periodic_save()
		local call = helper.find_call(rec, "call_after")
		assert.is_not_nil(call)
		assert.are.equal(900, call.seconds)
	end)

	it("saves the workspace snapshot when the timer fires", function()
		state_manager.periodic_save()
		-- The mock records the scheduled callback instead of running it; fire it once.
		local call = helper.find_call(rec, "call_after")
		call.fn()

		assert.are.equal(1, #saved)
		assert.are.equal("snapshot", saved[1].workspace)
	end)

	it("honours a custom interval and skips workspaces when disabled", function()
		state_manager.periodic_save({ interval_seconds = 5, save_workspaces = false })
		local call = helper.find_call(rec, "call_after")
		assert.are.equal(5, call.seconds)

		call.fn()
		assert.are.equal(0, #saved)
	end)

	it("skips windows that have not been user-named", function()
		local mock_mux_win = { get_title = function() return "mywin" end }
		wz.gui.gui_windows = function()
			return { { mux_window = function() return mock_mux_win end } }
		end

		state_manager.periodic_save({ save_workspaces = false, save_windows = true })
		local call = helper.find_call(rec, "call_after")
		call.fn()

		assert.are.equal(0, #saved)
	end)

	it("saves and re-stamps a user-named window", function()
		local mock_mux_win = { get_title = function() return "mywin" end }
		wz.gui.gui_windows = function()
			return { { mux_window = function() return mock_mux_win end } }
		end
		require("resurrect.window_state").get_window_state = function()
			return { title = "mywin", tabs = {} }
		end
		state_manager.is_user_named = function(name, type)
			return name == "mywin" and type == "window"
		end

		state_manager.periodic_save({ save_workspaces = false, save_windows = true })
		local call = helper.find_call(rec, "call_after")
		call.fn()

		assert.are.equal(1, #saved)
		assert.is_true(saved[1].user_named)
	end)
end)
