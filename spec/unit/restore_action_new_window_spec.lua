-- fuzzy_loader.restore_action used to default to restoring workspaces in place into the
-- window the picker was invoked from (current_window = true), via
-- restore_opts.window = pane:window(). That's surprising: opening a saved workspace
-- could silently dump its tabs into whatever window you happened to be in. Workspace
-- (and window) restores should always spawn a fresh window and never touch the
-- invoking window, matching tmux-resurrect and matching how window-type restores
-- already behaved.

local helper = require("spec_helper")

describe("fuzzy_loader.restore_action: workspace restores never reuse the invoking window", function()
	local fuzzy_loader, workspace_state_calls

	before_each(function()
		local wz = helper.new_wezterm()
		fuzzy_loader = helper.load("resurrect.fuzzy_loader", wz)

		local state_manager = require("resurrect.state_manager")
		state_manager.load_state = function(_, _)
			return { workspace = "myws", window_states = {} }
		end

		local workspace_state = require("resurrect.workspace_state")
		workspace_state_calls = {}
		workspace_state.restore_workspace = function(state, opts)
			table.insert(workspace_state_calls, { state = state, opts = opts })
		end

		-- Bypass the real picker (file IO, choice formatting): immediately invoke the
		-- dispatch callback as if the user had picked a workspace entry.
		fuzzy_loader.fuzzy_load = function(_win, _pane, callback, _picker_opts)
			callback("workspace/myws.json", "myws")
		end
	end)

	it("never sets opts.window, even if the caller passes current_window = true", function()
		local action = fuzzy_loader.restore_action({ current_window = true })
		action({}, { window = function()
			return {}
		end })

		assert.are.equal(1, #workspace_state_calls)
		assert.is_nil(workspace_state_calls[1].opts.window)
		assert.is_nil(workspace_state_calls[1].opts.current_window)
	end)

	it("never sets opts.window with no opts passed at all", function()
		local action = fuzzy_loader.restore_action()
		action({}, { window = function()
			return {}
		end })

		assert.are.equal(1, #workspace_state_calls)
		assert.is_nil(workspace_state_calls[1].opts.window)
	end)
end)
