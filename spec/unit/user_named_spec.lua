-- Covers the contract of state_manager.is_user_named: the quiet file-based
-- check that drives the prompt-once-per-entity behaviour.

local helper = require("spec_helper")

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
