-- The fuzzy-loader callback in the README does
--   `resurrect.state_manager.load_state(id, "workspace")` and passes the result
-- straight into restore_workspace. load_state must return the parsed table on
-- success and an empty table (never nil) on a missing/corrupt file, otherwise the
-- restore path errors out. These tests pin both halves of that contract.

local helper = require("spec_helper")

describe("state_manager.load_state", function()
	local state_manager, file_io

	before_each(function()
		local wz = helper.new_wezterm()
		state_manager = helper.load("resurrect.state_manager", wz)
		state_manager.save_state_dir = "/states/"
		file_io = require("resurrect.file_io")
	end)

	it("returns the parsed json table on success", function()
		local parsed = { workspace = "proj", window_states = {} }
		file_io.load_json = function()
			return parsed
		end

		local result = state_manager.load_state("proj", "workspace")
		assert.are.equal(parsed, result)
	end)

	it("returns an empty table (not nil) when the file is missing or invalid", function()
		file_io.load_json = function()
			return nil
		end

		local result = state_manager.load_state("missing", "workspace")
		assert.are.same({}, result)
		assert.is_not_nil(result)
	end)

	it("reads from <dir>/<type>/<name>.json", function()
		local seen_path
		file_io.load_json = function(path)
			seen_path = path
			return {}
		end

		state_manager.load_state("proj", "workspace")
		assert.are.equal("/states/workspace/proj.json", seen_path)
	end)
end)
