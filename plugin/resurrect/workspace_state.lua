local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local window_state_mod = require("resurrect.window_state")
local state_manager_mod = require("resurrect.state_manager")

local pub = {}

---restore workspace state
---@param workspace_state workspace_state
---@param opts? restore_opts
function pub.restore_workspace(workspace_state, opts)
	if workspace_state == nil then
		return
	end

	wezterm.emit("resurrect.workspace_state.restore_workspace.start")
	if opts == nil then
		opts = {}
	end

	-- Wrapped in pcall so a thrown error partway through (bad spawn args, a
	-- malformed saved pane_tree, etc.) surfaces as resurrect.error instead of
	-- aborting silently with .start fired and no .finished or error signal.
	local ok, result = pcall(function()
		-- Default to restoring the windows into (and switching to) the saved
		-- workspace. Pass `spawn_in_workspace = false` to keep the legacy behaviour of
		-- spawning them into the "default" workspace without switching.
		if opts.spawn_in_workspace == nil then
			opts.spawn_in_workspace = true
		end

		-- Whether to switch the active workspace to the restored one. `switch_workspace`
		-- is nil by default and falls back to `spawn_in_workspace`, preserving the
		-- behaviour of callers that set neither. Pass `switch_workspace = false` to opt out.
		local should_switch_workspace = opts.switch_workspace
		if should_switch_workspace == nil then
			should_switch_workspace = opts.spawn_in_workspace
		end

		-- Spawn windows into the target workspace whenever we'll switch to it too: switching
		-- into a workspace with no windows crashes, so a switch intent forces the spawn-in
		-- even when spawn_in_workspace is false. Full spawn × switch matrix (target not already
		-- live; the live case is the guard below); (FIX) marks the two combos that changed:
		--
		--   spawn_in_workspace | switch_workspace | spawn into target? | result
		--   -------------------+------------------+--------------------+-------------------------
		--   true (default)     | true / unset     | yes                | spawn into target, switch to it
		--   true               | false            | yes                | spawn into target, stay put   (FIX: was rename → 2 workspaces aliased)
		--   false              | false / unset    | no                 | spawn into current, rename current → target (legacy)
		--   false              | true             | yes                | spawn into target, switch     (FIX: was spawn-into-current then switch-empty → crash)
		local spawn_window_in_workspace = opts.spawn_in_workspace or should_switch_workspace

		-- Already-live workspace: switch to it (when should_switch_workspace) rather than
		-- restore a duplicate window set that the next save would persist. Safe on
		-- gui-startup: the mux is empty when it fires, so nothing matches here.
		local target = workspace_state.workspace
		if target and target ~= "" then
			for _, mux_win in ipairs(wezterm.mux.all_windows()) do
				if mux_win:get_workspace() == target then
					if should_switch_workspace then
						wezterm.mux.set_active_workspace(target)
					end
					return true
				end
			end
		end

		for i, window_state in ipairs(workspace_state.window_states) do
			if i == 1 and opts.window then
				-- inner size is in pixels
				if opts.resize_window == true or opts.resize_window == nil then
					opts.window
						:gui_window()
						:set_inner_size(window_state.size.pixel_width, window_state.size.pixel_height)
				end
				if not opts.close_open_tabs then
					opts.tab = opts.window:active_tab()
					if not opts.close_open_panes then
						opts.pane = opts.window:active_pane()
						-- Flagged explicitly rather than inferred at restore time by comparing
						-- cwds: get_current_working_dir() isn't reliably populated immediately
						-- after a fresh spawn, so a runtime comparison would race for the
						-- common case.
						opts.pane_needs_cd = true
					end
				end
			else
				local spawn_window_args = {
					width = window_state.size.cols,
					height = window_state.size.rows,
					cwd = window_state.tabs[1].pane_tree.cwd,
				}
				if spawn_window_in_workspace then
					spawn_window_args.workspace = workspace_state.workspace
				end
				opts.tab, opts.pane, opts.window = wezterm.mux.spawn_window(spawn_window_args)
			end

			window_state_mod.restore_window(opts.window, window_state, opts)
		end

		-- window_states can be saved empty (e.g. a save-time mux race), in which case
		-- the loop above never spawned or reused a window for this workspace. Switching
		-- into it below would then crash with "<name> is not an existing workspace".
		if opts.window == nil then
			local msg = "workspace '" .. tostring(workspace_state.workspace) .. "' has no windows to restore; skipping"
			wezterm.log_warn("resurrect: " .. msg)
			wezterm.emit("resurrect.error", msg)
			return false -- signal: skip .finished below, this isn't an error
		end

		-- Switch the active workspace to the one just restored, so the user actually
		-- lands in it rather than staying in (or being dropped into) another workspace.
		-- should_switch_workspace was resolved above, next to the already-live guard.
		if workspace_state.workspace and workspace_state.workspace ~= "" then
			if should_switch_workspace then
				wezterm.mux.set_active_workspace(workspace_state.workspace)
			elseif not spawn_window_in_workspace then
				-- Windows landed in the current workspace (spawn_in_workspace=false and not
				-- switching): rename it to the restored name so it no longer shows up as
				-- "default". Gated on `not spawn_window_in_workspace`, not on
				-- `not should_switch_workspace`: when the windows were spawned into the target
				-- instead (spawn_in_workspace=true, switch=false) a rename would alias two
				-- workspaces to the same name.
				wezterm.mux.rename_workspace(wezterm.mux.get_active_workspace(), workspace_state.workspace)
			end
		end

		return true
	end)

	if not ok then
		wezterm.log_error("resurrect: restore_workspace failed: " .. tostring(result))
		wezterm.emit("resurrect.error", "restore_workspace failed: " .. tostring(result))
		return
	end

	if result == false then
		return
	end

	wezterm.emit("resurrect.workspace_state.restore_workspace.finished")
end

---Returns a wezterm action that saves the current workspace state.
---Mirrors save_window_action() and save_tab_action() for use in custom key tables.
---Workspaces are named explicitly via create_workspace_action(), not prompted for
---on save — this just persists whatever the current workspace is.
---@return table wezterm action
function pub.save_workspace_action()
	return wezterm.action_callback(function(_win, _pane)
		state_manager_mod.save_state(pub.get_workspace_state())
	end)
end

---Returns a wezterm action that prompts for a name and switches to that
---workspace, creating it if it doesn't already exist.
---@return table wezterm action
function pub.create_workspace_action()
	return wezterm.action_callback(function(win, pane)
		win:perform_action(
			wezterm.action.PromptInputLine({
				description = "Enter a name for the new workspace | no name is a no-op",
				action = wezterm.action_callback(function(window, inner_pane, name)
					if name and name ~= "" then
						window:perform_action(wezterm.action.SwitchToWorkspace({ name = name }), inner_pane)
					end
				end),
			}),
			pane
		)
	end)
end

---Returns the state of the current workspace. An unnamed/default wezterm
---workspace ("" or nil) is persisted under "default".
---@return workspace_state
function pub.get_workspace_state()
	local current = wezterm.mux.get_active_workspace()
	local workspace_state = {
		workspace = (current and current ~= "") and current or "default",
		window_states = {},
	}
	for _, mux_win in ipairs(wezterm.mux.all_windows()) do
		if mux_win:get_workspace() == current then
			table.insert(workspace_state.window_states, window_state_mod.get_window_state(mux_win))
		end
	end
	return workspace_state
end

return pub
