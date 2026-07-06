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
		-- ...but does not switch the active workspace...
		assert.is_nil(helper.find_call(rec, "set_active_workspace"))
		-- ...and does not rename the current workspace to the target's name. The windows
		-- landed in the target (tagged), so renaming would alias two workspaces to "myws".
		assert.is_nil(helper.find_call(rec, "rename_workspace"))
	end)

	it("spawn_in_workspace=false + switch_workspace=true forces the tag so the switch lands", function()
		workspace_state.restore_workspace(sample_state(), {
			spawn_in_workspace = false,
			switch_workspace = true,
		})

		-- The switch intent forces windows to be tagged into the target, so the workspace
		-- is populated before the switch (otherwise set_active_workspace crashes on an
		-- empty workspace name).
		local spawn = helper.find_call(rec, "spawn_window")
		assert.are.equal("myws", spawn.args.workspace)

		local switch = helper.find_call(rec, "set_active_workspace")
		assert.is_not_nil(switch)
		assert.are.equal("myws", switch.workspace)

		assert.is_nil(helper.find_call(rec, "rename_workspace"))
	end)

	-- Out of scope: a caller reusing an existing window (opts.window) with a single-window
	-- state + truthy switch intent can still hit an empty-switch — the reused window isn't
	-- retagged and there is no MuxWindow:set_workspace. The fuzzy picker forces window=nil,
	-- so it never triggers there; not solved here.

	it("returns without side effects when the state is nil", function()
		workspace_state.restore_workspace(nil)
		assert.is_nil(helper.find_call(rec, "spawn_window"))
		assert.is_nil(helper.find_call(rec, "set_active_workspace"))
	end)

	it("skips spawn/switch when window_states is empty, instead of crashing", function()
		workspace_state.restore_workspace({ workspace = "zz", window_states = {} })
		assert.is_nil(helper.find_call(rec, "spawn_window"))
		assert.is_nil(helper.find_call(rec, "set_active_workspace"))
	end)
end)
