-- Restoring a workspace in place into the current window (opts.window passed by the
-- caller, e.g. fuzzy_loader's default current_window=true) used to call
-- set_active_workspace(workspace_state.workspace) unconditionally to "land" the user in
-- the restored workspace. That only works when a window was actually spawned into that
-- named workspace; the reused window 1 never was, so set_active_workspace had nothing to
-- switch to and the window silently kept its old workspace name (e.g. "default"). It
-- needs a rename instead, applied to whichever workspace the reused window actually
-- belongs to.

local helper = require("spec_helper")

describe("workspace_state.restore_workspace renaming the reused window's workspace", function()
	local workspace_state, window_state, rec

	local function sample_state()
		return {
			workspace = "dotfiles-dev",
			window_states = {
				{
					size = { cols = 80, rows = 24, pixel_width = 800, pixel_height = 600 },
					tabs = { { pane_tree = { cwd = "/home" } } },
				},
			},
		}
	end

	local function make_window(workspace_name)
		return {
			gui_window = function()
				return { set_inner_size = function() end }
			end,
			active_tab = function()
				return {}
			end,
			active_pane = function()
				return {}
			end,
			get_workspace = function()
				return workspace_name
			end,
		}
	end

	before_each(function()
		local wz
		wz, rec = helper.new_wezterm({ active_workspace = "default" })
		workspace_state = helper.load("resurrect.workspace_state", wz)
		-- restore_window does heavy mux work that is out of scope here; stub it so we
		-- only observe restore_workspace's own rename/switch decision.
		window_state = require("resurrect.window_state")
		window_state.restore_window = function() end
	end)

	it("renames the reused window's current workspace instead of switching to a nonexistent one", function()
		local win = make_window("default")
		workspace_state.restore_workspace(sample_state(), { window = win })

		local rename = helper.find_call(rec, "rename_workspace")
		assert.is_not_nil(rename, "expected the reused window's workspace to be renamed")
		assert.are.equal("default", rename.from)
		assert.are.equal("dotfiles-dev", rename.to)

		assert.is_nil(helper.find_call(rec, "set_active_workspace"))
	end)

	it("falls back to the legacy active-workspace rename when switch_workspace=false", function()
		local win = make_window("default")
		workspace_state.restore_workspace(sample_state(), { window = win, switch_workspace = false })

		local rename = helper.find_call(rec, "rename_workspace")
		assert.is_not_nil(rename)
		-- Legacy branch renames wezterm.mux.get_active_workspace(), not the reused
		-- window's own workspace -- they happen to be equal here ("default"), but the
		-- source is different, which the next assertion on call count pins.
		assert.are.equal("default", rename.from)
		assert.are.equal("dotfiles-dev", rename.to)

		local rename_calls = 0
		for _, call in ipairs(rec.calls) do
			if call.name == "rename_workspace" then
				rename_calls = rename_calls + 1
			end
		end
		assert.are.equal(1, rename_calls)
	end)
end)
