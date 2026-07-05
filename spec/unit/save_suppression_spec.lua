-- Saves fired while a restore is in flight persist half-built panes over the
-- state that was just restored: wezterm delivers the focus/structure events
-- queued during a restore before the restored panes have settled, which was
-- the poisoning path that made compounding prompt blocks survive process
-- restarts. Restore entry points extend a suppression window; event-driven
-- and periodic saves inside it are skipped, and both resume once it expires.

local helper = require("spec_helper")

local function find_on(rec, event)
	for _, call in ipairs(rec.calls) do
		if call.name == "on" and call.event == event then
			return call
		end
	end
end

local function mock_window(id, focused)
	return {
		window_id = function()
			return id
		end,
		is_focused = function()
			return focused
		end,
	}
end

describe("state_manager save suppression during restore", function()
	local wz, rec, state_manager, saved
	local real_time = os.time

	before_each(function()
		wz, rec = helper.new_wezterm()
		state_manager = helper.load("resurrect.state_manager", wz)

		-- Observe save_state without touching disk, and short-circuit the
		-- workspace snapshot (which would need a full mux mock).
		saved = {}
		state_manager.save_state = function(state)
			table.insert(saved, state)
		end
		state_manager.is_user_named = function()
			return false
		end
		require("resurrect.workspace_state").get_workspace_state = function()
			return { workspace = "snapshot", window_states = {} }
		end
	end)

	after_each(function()
		os.time = real_time
	end)

	it("skips a focus-loss save inside the window and saves again after it expires", function()
		os.time = function()
			return 1000
		end
		state_manager.event_driven_save()
		state_manager.extend_save_suppression(5)

		local on_focus = find_on(rec, "window-focus-changed")
		on_focus.fn(mock_window("w1", false))
		assert.are.equal(0, #saved)

		-- Past both the suppression window and the focus-loss debounce.
		os.time = function()
			return 1011
		end
		on_focus.fn(mock_window("w1", true))
		on_focus.fn(mock_window("w1", false))
		assert.are.equal(1, #saved)
	end)

	it("extends but never shortens the window", function()
		os.time = function()
			return 1000
		end
		state_manager.event_driven_save()
		state_manager.extend_save_suppression(30)
		state_manager.extend_save_suppression(5)

		os.time = function()
			return 1011
		end
		local on_focus = find_on(rec, "window-focus-changed")
		on_focus.fn(mock_window("w1", false))
		assert.are.equal(0, #saved)
	end)

	it("skips a periodic save inside the window but keeps the timer chain alive", function()
		os.time = function()
			return 1000
		end
		state_manager.extend_save_suppression(5)
		state_manager.periodic_save({ interval_seconds = 60, save_workspaces = true })

		local timers = {}
		for _, call in ipairs(rec.calls) do
			if call.name == "call_after" then
				table.insert(timers, call)
			end
		end
		assert.are.equal(1, #timers)
		timers[1].fn()
		assert.are.equal(0, #saved)

		-- The skipped tick must have rescheduled; the next tick, after the
		-- window expires, saves normally.
		timers = {}
		for _, call in ipairs(rec.calls) do
			if call.name == "call_after" then
				table.insert(timers, call)
			end
		end
		assert.are.equal(2, #timers)
		os.time = function()
			return 1070
		end
		timers[2].fn()
		assert.are.equal(1, #saved)
	end)
end)
