-- periodic_save is the headline "save my session every 15 minutes" feature from
-- the README. These tests pin the documented default interval and that the
-- scheduled callback actually saves a workspace, without waiting on a real timer.

local helper = require("spec_helper")

describe("state_manager.periodic_save", function()
	local state_manager, rec, saved

	before_each(function()
		local wz
		wz, rec = helper.new_wezterm()
		state_manager = helper.load("resurrect.state_manager", wz)

		-- Observe save_state without touching disk, and short-circuit the workspace
		-- snapshot (which would need a full mux mock).
		saved = {}
		state_manager.save_state = function(state)
			table.insert(saved, state)
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
end)
