-- delete_state removes a file by name straight off disk. Since the name
-- ultimately comes from a saved-state listing, these tests pin the path
-- confinement rules (no traversal, no absolute paths, .json only) so a future
-- change can't turn this into an arbitrary-file-delete primitive.

local helper = require("spec_helper")

describe("state_manager.delete_state", function()
	local state_manager, rec, original_remove, removed

	before_each(function()
		local wz
		wz, rec = helper.new_wezterm()
		state_manager = helper.load("resurrect.state_manager", wz)
		state_manager.change_state_save_dir("/states/")

		removed = {}
		original_remove = os.remove
		os.remove = function(path)
			table.insert(removed, path)
			return true
		end
	end)

	after_each(function()
		os.remove = original_remove
	end)

	it("deletes a well-formed relative json path", function()
		state_manager.delete_state("workspace/proj.json")
		assert.are.equal(1, #removed)
		assert.are.equal("/states/workspace/proj.json", removed[1])
	end)

	it("rejects paths containing '..'", function()
		state_manager.delete_state("../etc/passwd.json")
		assert.are.equal(0, #removed)
		assert.is_not_nil(helper.find_emit(rec, "resurrect.error"))
	end)

	it("rejects absolute unix paths", function()
		state_manager.delete_state("/etc/passwd.json")
		assert.are.equal(0, #removed)
	end)

	it("rejects absolute windows paths", function()
		state_manager.delete_state("C:\\Windows\\system.json")
		assert.are.equal(0, #removed)
	end)

	it("rejects non-json extensions", function()
		state_manager.delete_state("workspace/proj.lua")
		assert.are.equal(0, #removed)
	end)
end)
