-- event_driven_save's save-on-focus-loss trigger: a window-focus-changed listener
-- that saves on a focused->unfocused transition, ignoring gains and duplicate
-- unfocused firings, and debounced so rapid alt-tabbing can't spam saves. This is
-- also the first test coverage for event_driven_save itself.

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

describe("state_manager.event_driven_save — save_on_focus_loss", function()
	local state_manager, rec, saved, wz
	local real_time = os.time

	before_each(function()
		wz, rec = helper.new_wezterm()
		state_manager = helper.load("resurrect.state_manager", wz)

		-- Observe save_state without touching disk, and short-circuit the workspace
		-- snapshot (which would need a full mux mock).
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

	it("registers window-focus-changed by default", function()
		state_manager.event_driven_save()
		assert.is_not_nil(find_on(rec, "window-focus-changed"))
	end)

	it("does not register window-focus-changed when disabled", function()
		state_manager.event_driven_save({ save_on_focus_loss = false })
		assert.is_nil(find_on(rec, "window-focus-changed"))
	end)

	it("saves on the very first event for a window when it reports unfocused", function()
		state_manager.event_driven_save()
		local on_focus = find_on(rec, "window-focus-changed")
		on_focus.fn(mock_window("w1", false))
		assert.are.equal(1, #saved)
	end)

	it("does not save on a gain event", function()
		state_manager.event_driven_save()
		local on_focus = find_on(rec, "window-focus-changed")
		on_focus.fn(mock_window("w1", true))
		assert.are.equal(0, #saved)
	end)

	it("saves exactly once on a focused -> unfocused transition", function()
		state_manager.event_driven_save()
		local on_focus = find_on(rec, "window-focus-changed")
		on_focus.fn(mock_window("w1", true)) -- seeds state, no save
		on_focus.fn(mock_window("w1", false)) -- transition, saves
		assert.are.equal(1, #saved)
	end)

	it("does not save again on a duplicate unfocused event, even after the debounce window", function()
		os.time = function()
			return 1000
		end
		state_manager.event_driven_save()
		local on_focus = find_on(rec, "window-focus-changed")
		on_focus.fn(mock_window("w1", false))

		os.time = function()
			return 1020
		end
		on_focus.fn(mock_window("w1", false))

		assert.are.equal(1, #saved)
	end)

	it("tracks windows independently", function()
		state_manager.event_driven_save()
		local on_focus = find_on(rec, "window-focus-changed")
		on_focus.fn(mock_window("w1", true)) -- seed w1 as focused, no save
		on_focus.fn(mock_window("w2", false)) -- w2's first event, unfocused -> saves
		assert.are.equal(1, #saved)
	end)

	it("emits the shared event_driven_save start/finished events on a focus-loss save", function()
		state_manager.event_driven_save()
		local on_focus = find_on(rec, "window-focus-changed")
		on_focus.fn(mock_window("w1", false))
		assert.is_not_nil(helper.find_emit(rec, "resurrect.state_manager.event_driven_save.start"))
		assert.is_not_nil(helper.find_emit(rec, "resurrect.state_manager.event_driven_save.finished"))
	end)

	it("debounces rapid focus-loss saves across different windows", function()
		os.time = function()
			return 5000
		end
		state_manager.event_driven_save()
		local on_focus = find_on(rec, "window-focus-changed")
		on_focus.fn(mock_window("w1", false)) -- first event, saves
		on_focus.fn(mock_window("w2", false)) -- different window, within debounce window -- skipped
		assert.are.equal(1, #saved)
	end)

	it("saves again once the debounce window has elapsed", function()
		os.time = function()
			return 5000
		end
		state_manager.event_driven_save()
		local on_focus = find_on(rec, "window-focus-changed")
		on_focus.fn(mock_window("w1", false))

		os.time = function()
			return 5011
		end
		on_focus.fn(mock_window("w2", false))

		assert.are.equal(2, #saved)
	end)
end)
