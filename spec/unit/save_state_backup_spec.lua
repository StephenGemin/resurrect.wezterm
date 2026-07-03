-- save_state used to overwrite the canonical file in place, so a degraded
-- save (partial restore, accidental window close) could permanently clobber
-- the last good snapshot. These tests pin that save_state now rolls any
-- existing file to a ".bak" sibling before writing the new one, and only
-- writes state -- never touches .bak -- on a first save.

local helper = require("spec_helper")

describe("state_manager.save_state backup rotation", function()
	local state_manager, file_io, moves, writes

	before_each(function()
		local wz = helper.new_wezterm()
		state_manager = helper.load("resurrect.state_manager", wz)
		state_manager.change_state_save_dir("/states/")

		file_io = require("resurrect.file_io")
		moves = {}
		writes = {}
		file_io.write_state = function(path, _state, event_type)
			table.insert(writes, { path = path, event_type = event_type })
		end
		file_io.move_file = function(src, dst)
			table.insert(moves, { src = src, dst = dst })
			return true
		end
	end)

	it("rolls the existing file to .bak before writing when one is present", function()
		file_io.file_exists = function()
			return true
		end
		state_manager.save_state({ workspace = "proj", window_states = {} })

		assert.are.equal(1, #moves)
		assert.are.equal("/states/workspace/proj.json", moves[1].src)
		assert.are.equal("/states/workspace/proj.json.bak", moves[1].dst)
		assert.are.equal(1, #writes)
	end)

	it("does not rotate on a first save, when no file exists yet", function()
		file_io.file_exists = function()
			return false
		end
		state_manager.save_state({ workspace = "proj", window_states = {} })

		assert.are.equal(0, #moves)
		assert.are.equal(1, #writes)
	end)
end)
