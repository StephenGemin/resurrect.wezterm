-- save_state decides the file type and on-disk path purely from the shape of the
-- state table. If that routing breaks, saved files land in the wrong directory or
-- under the wrong name and become unloadable -- a silent, user-facing data-loss
-- bug. These tests pin the documented behaviour.

local helper = require("spec_helper")

describe("state_manager.save_state", function()
	local state_manager, file_io, writes

	before_each(function()
		local wz = helper.new_wezterm()
		state_manager = helper.load("resurrect.state_manager", wz)
		-- Pin a known directory instead of going through change_state_save_dir (which
		-- would touch the filesystem); save_state only reads save_state_dir.
		state_manager.save_state_dir = "/states/"

		-- Capture what would be written without hitting disk or JSON encoding.
		file_io = require("resurrect.file_io")
		writes = {}
		file_io.write_state = function(path, _state, event_type)
			table.insert(writes, { path = path, event_type = event_type })
		end
	end)

	it("routes a workspace state to the workspace/ dir, named by workspace", function()
		state_manager.save_state({ workspace = "proj", window_states = {} })
		assert.are.equal("/states/workspace/proj.json", writes[1].path)
		assert.are.equal("workspace", writes[1].event_type)
	end)

	it("routes a window state to the window/ dir, named by title", function()
		state_manager.save_state({ title = "main", tabs = {} })
		assert.are.equal("/states/window/main.json", writes[1].path)
		assert.are.equal("window", writes[1].event_type)
	end)

	it("routes a tab state to the tab/ dir, named by title", function()
		state_manager.save_state({ title = "editor", pane_tree = {} })
		assert.are.equal("/states/tab/editor.json", writes[1].path)
		assert.are.equal("tab", writes[1].event_type)
	end)

	it("replaces path separators in the name so the file stays in one directory", function()
		state_manager.save_state({ workspace = "a/b/c", window_states = {} })
		assert.are.equal("/states/workspace/a+b+c.json", writes[1].path)
	end)

	it("honours the opt_name override for the filename", function()
		state_manager.save_state({ workspace = "proj", window_states = {} }, "custom")
		assert.are.equal("/states/workspace/custom.json", writes[1].path)
	end)

	it("sanitises a path separator in the opt_name override so it stays in one directory", function()
		state_manager.save_state({ workspace = "proj", window_states = {} }, "team/custom")
		assert.are.equal("/states/workspace/team+custom.json", writes[1].path)
	end)

	it("does not write anything for an unrecognised state shape", function()
		state_manager.save_state({ something = "else" })
		assert.are.equal(0, #writes)
	end)
end)
