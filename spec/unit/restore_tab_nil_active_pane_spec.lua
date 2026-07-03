-- acc.active_pane is only populated by make_splits when some node in the saved
-- pane_tree has is_active = true. A malformed or hand-edited state file can
-- omit that flag entirely, in which case restore_tab used to crash on
-- acc.active_pane:activate() indexing nil. These tests pin that restore_tab
-- degrades gracefully instead of throwing.

local helper = require("spec_helper")

describe("tab_state.restore_tab with no active pane in the saved tree", function()
	local tab_state

	local function make_pane()
		return {
			activate = function() end,
			send_text = function() end,
		}
	end

	before_each(function()
		local wz = helper.new_wezterm()
		tab_state = helper.load("resurrect.tab_state", wz)
	end)

	it("does not throw when no node in pane_tree is marked active", function()
		local pane_tree = { cwd = "/home/testuser/project", is_active = false }
		assert.has_no.errors(function()
			tab_state.restore_tab({}, { pane_tree = pane_tree }, { pane = make_pane() })
		end)
	end)

	it("still activates the pane when one node is marked active", function()
		local activated = false
		local pane = make_pane()
		pane.activate = function()
			activated = true
		end
		local pane_tree = { cwd = "/home/testuser/project", is_active = true }
		tab_state.restore_tab({}, { pane_tree = pane_tree }, { pane = pane })
		assert.is_true(activated)
	end)
end)
