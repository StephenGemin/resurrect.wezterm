-- restore_workspace's defaults are the most breaking-change-sensitive behaviour
-- in the plugin: README has an explicit WARNING that `spawn_in_workspace` now
-- defaults to true (a change from older versions). These tests pin the documented
-- matrix so an accidental regression to the old defaults fails CI.

local helper = require("spec_helper")

describe("workspace_state.restore_workspace defaults", function()
	local workspace_state, window_state, rec

	-- A minimal single-window state, plus opts with no `window` so restore goes
	-- through the mux.spawn_window branch where the workspace name is applied.
	local function sample_state()
		return {
			workspace = "myws",
			window_states = {
				{
					size = { cols = 80, rows = 24, pixel_width = 800, pixel_height = 600 },
					tabs = { { pane_tree = { cwd = "/home" } } },
				},
			},
		}
	end

	before_each(function()
		local wz
		wz, rec = helper.new_wezterm({
			active_workspace = "default",
			spawn_window_result = { tab = {}, pane = {}, window = {} },
		})
		workspace_state = helper.load("resurrect.workspace_state", wz)
		-- restore_window does heavy mux work that is out of scope here; stub it so we
		-- only observe restore_workspace's own spawn/switch decisions.
		window_state = require("resurrect.window_state")
		window_state.restore_window = function() end
	end)

	it("defaults spawn_in_workspace=true: spawns into and switches to the saved workspace", function()
		workspace_state.restore_workspace(sample_state())

		local spawn = helper.find_call(rec, "spawn_window")
		assert.is_not_nil(spawn)
		assert.are.equal("myws", spawn.args.workspace)

		local switch = helper.find_call(rec, "set_active_workspace")
		assert.is_not_nil(switch, "expected the active workspace to be switched to 'myws'")
		assert.are.equal("myws", switch.workspace)

		assert.is_nil(helper.find_call(rec, "rename_workspace"))
	end)

	it("spawn_in_workspace=false keeps the legacy behaviour: spawns into default, renames, no switch", function()
		workspace_state.restore_workspace(sample_state(), { spawn_in_workspace = false })

		local spawn = helper.find_call(rec, "spawn_window")
		assert.is_not_nil(spawn)
		assert.is_nil(spawn.args.workspace, "windows should spawn into the default workspace")

		assert.is_nil(helper.find_call(rec, "set_active_workspace"))

		local rename = helper.find_call(rec, "rename_workspace")
		assert.is_not_nil(rename)
		assert.are.equal("default", rename.from)
		assert.are.equal("myws", rename.to)
	end)

	it("switch_workspace=false opts out of switching independently of spawn", function()
		workspace_state.restore_workspace(sample_state(), {
			spawn_in_workspace = true,
			switch_workspace = false,
		})

		-- Still spawns into the saved workspace...
		local spawn = helper.find_call(rec, "spawn_window")
		assert.are.equal("myws", spawn.args.workspace)
		-- ...but does not switch the active workspace.
		assert.is_nil(helper.find_call(rec, "set_active_workspace"))
	end)

	it("returns without side effects when the state is nil", function()
		workspace_state.restore_workspace(nil)
		assert.is_nil(helper.find_call(rec, "spawn_window"))
		assert.is_nil(helper.find_call(rec, "set_active_workspace"))
	end)
end)
