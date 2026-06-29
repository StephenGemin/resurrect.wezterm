-- Covers the three behaviours introduced by the user-assigned name feature:
--   1. state_manager.is_user_named — quiet file-based check
--   2. save_window_action — prompt only on first save; silent thereafter
--   3. on_state_deleted — resets window/tab title so the next save re-prompts

local helper = require("spec_helper")

-- ─── is_user_named ───────────────────────────────────────────────────────────

describe("state_manager.is_user_named", function()
	local state_manager, file_io

	before_each(function()
		local wz = helper.new_wezterm()
		state_manager = helper.load("resurrect.state_manager", wz)
		state_manager.change_state_save_dir("/states/")
		file_io = require("resurrect.file_io")
	end)

	it("returns false when the state file does not exist", function()
		file_io.load_json = function()
			return nil
		end
		assert.is_false(state_manager.is_user_named("mywin", "window"))
	end)

	it("returns false when the file exists but has no user_named field", function()
		file_io.load_json = function()
			return { title = "mywin" }
		end
		assert.is_false(state_manager.is_user_named("mywin", "window"))
	end)

	it("returns true when the file contains user_named = true", function()
		file_io.load_json = function()
			return { title = "mywin", user_named = true }
		end
		assert.is_true(state_manager.is_user_named("mywin", "window"))
	end)
end)

-- ─── save_window_action — prompt behaviour ───────────────────────────────────

describe("save_window_action", function()
	local window_state, file_io

	local function make_mock_win(title, win_id)
		local actions = {}
		local mux = {
			window_id = function()
				return win_id or 1
			end,
			get_title = function()
				return title
			end,
			set_title = function() end,
		}
		local win = {
			_actions = actions,
			mux_window = function()
				return mux
			end,
			perform_action = function(_, action, _)
				table.insert(actions, action)
			end,
		}
		return win, actions
	end

	before_each(function()
		local wz = helper.new_wezterm()
		window_state = helper.load("resurrect.window_state", wz)
		local sm = require("resurrect.state_manager")
		sm.change_state_save_dir("/states/")
		file_io = require("resurrect.file_io")
		file_io.write_state = function() end
		-- Stub get_window_state to avoid the full tab/pane mock chain
		window_state.get_window_state = function()
			return { title = "stub", tabs = {} }
		end
	end)

	it("shows PromptInputLine when the window has no saved user_named state", function()
		file_io.load_json = function()
			return nil
		end
		local action_fn = window_state.save_window_action()
		local win, actions = make_mock_win("zsh+in+bin")
		action_fn(win, {})
		assert.equals(1, #actions)
		assert.equals("PromptInputLine", actions[1].__action)
	end)

	it("saves silently (no PromptInputLine) when the file has user_named = true", function()
		file_io.load_json = function()
			return { title = "dev", user_named = true }
		end
		local action_fn = window_state.save_window_action()
		local win, actions = make_mock_win("dev")
		action_fn(win, {})
		assert.equals(0, #actions)
	end)
end)

-- ─── on_state_deleted — title reset ──────────────────────────────────────────

describe("window_state.on_state_deleted", function()
	it("resets the matching window title to an empty string", function()
		local reset_to
		local mock_win = {
			get_title = function()
				return "dev"
			end,
			set_title = function(_, t)
				reset_to = t
			end,
		}
		local wz = helper.new_wezterm({ all_windows = { mock_win } })
		local ws = helper.load("resurrect.window_state", wz)
		ws.on_state_deleted("dev")
		assert.equals("", reset_to)
	end)

	it("does not touch windows with a different title", function()
		local touched = false
		local mock_win = {
			get_title = function()
				return "other"
			end,
			set_title = function()
				touched = true
			end,
		}
		local wz = helper.new_wezterm({ all_windows = { mock_win } })
		local ws = helper.load("resurrect.window_state", wz)
		ws.on_state_deleted("dev")
		assert.is_false(touched)
	end)
end)

describe("tab_state.on_state_deleted", function()
	local function make_mock_window_with_tab(tab_title)
		local reset_to
		local mock_tab = {
			get_title = function()
				return tab_title
			end,
			set_title = function(_, t)
				reset_to = t
			end,
		}
		local mock_win = {
			tabs = function()
				return { mock_tab }
			end,
		}
		return mock_win, function()
			return reset_to
		end
	end

	it("resets the matching tab title to an empty string", function()
		local mock_win, get_reset = make_mock_window_with_tab("editor")
		local wz = helper.new_wezterm({ all_windows = { mock_win } })
		local ts = helper.load("resurrect.tab_state", wz)
		ts.on_state_deleted("editor")
		assert.equals("", get_reset())
	end)

	it("does not touch tabs with a different title", function()
		local mock_win, get_reset = make_mock_window_with_tab("other")
		local wz = helper.new_wezterm({ all_windows = { mock_win } })
		local ts = helper.load("resurrect.tab_state", wz)
		ts.on_state_deleted("editor")
		assert.is_nil(get_reset())
	end)
end)
