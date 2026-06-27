-- Guards the public API surface that the README setup example depends on.
--
-- Every entry below is referenced verbatim in README.md. If a refactor renames
-- or moves one of these, a user's `wezterm.lua` breaks at load time with a
-- "attempt to call a nil value" error. These assertions turn that into a CI
-- failure instead.

local helper = require("spec_helper")

describe("public API surface (README contract)", function()
	-- module name -> { field = expected lua type }
	local expected = {
		["resurrect.state_manager"] = {
			save_state = "function",
			load_state = "function",
			delete_state = "function",
			periodic_save = "function",
			set_encryption = "function",
			change_state_save_dir = "function",
			set_max_nlines = "function",
			write_current_state = "function",
			resurrect_on_gui_startup = "function",
		},
		["resurrect.workspace_state"] = {
			get_workspace_state = "function",
			restore_workspace = "function",
			save_workspace_action = "function",
		},
		["resurrect.window_state"] = {
			get_window_state = "function",
			save_window_action = "function",
			restore_window = "function",
		},
		["resurrect.tab_state"] = {
			get_tab_state = "function",
			save_tab_action = "function",
			restore_tab = "function",
			default_on_pane_restore = "function",
		},
		["resurrect.fuzzy_loader"] = {
			fuzzy_load = "function",
			restore_action = "function",
			delete_action = "function",
		},
	}

	for modname, fields in pairs(expected) do
		describe(modname, function()
			for field, kind in pairs(fields) do
				it("exports " .. field .. " as a " .. kind, function()
					local mod = helper.load(modname, helper.new_wezterm())
					assert.are.equal(kind, type(mod[field]), modname .. "." .. field .. " changed type")
				end)
			end
		end)
	end

	it("init.lua wires the submodules under the README names", function()
		local wz = helper.new_wezterm()
		local resurrect = helper.load("init", wz)

		assert.are.equal("function", type(resurrect.state_manager.save_state))
		assert.are.equal("function", type(resurrect.workspace_state.restore_workspace))
		assert.are.equal("function", type(resurrect.window_state.save_window_action))
		assert.are.equal("function", type(resurrect.tab_state.default_on_pane_restore))
		assert.are.equal("function", type(resurrect.fuzzy_loader.fuzzy_load))
	end)
end)
