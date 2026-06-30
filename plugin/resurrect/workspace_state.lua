local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local window_state_mod = require("resurrect.window_state")
local state_manager_mod = require("resurrect.state_manager")

local pub = {}

local _named_workspaces = {} -- {[workspace_name: string] = true}

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

	-- Default to restoring the windows into (and switching to) the saved
	-- workspace. Pass `spawn_in_workspace = false` to keep the legacy behaviour of
	-- spawning them into the "default" workspace without switching.
	if opts.spawn_in_workspace == nil then
		opts.spawn_in_workspace = true
	end

	for i, window_state in ipairs(workspace_state.window_states) do
		if i == 1 and opts.window then
			-- inner size is in pixels
			if opts.resize_window == true or opts.resize_window == nil then
				opts.window:gui_window():set_inner_size(window_state.size.pixel_width, window_state.size.pixel_height)
			end
			if not opts.close_open_tabs then
				opts.tab = opts.window:active_tab()
				if not opts.close_open_panes then
					opts.pane = opts.window:active_pane()
					-- This pane is being reused as-is, not spawned fresh with the
					-- right cwd already set, so restore_tab needs to actually cd it.
					opts.pane_needs_cd = true
				end
			end
		else
			local spawn_window_args = {
				width = window_state.size.cols,
				height = window_state.size.rows,
				cwd = window_state.tabs[1].pane_tree.cwd,
			}
			if opts.spawn_in_workspace then
				spawn_window_args.workspace = workspace_state.workspace
			end
			opts.tab, opts.pane, opts.window = wezterm.mux.spawn_window(spawn_window_args)
		end

		window_state_mod.restore_window(opts.window, window_state, opts)
	end

	-- Switch the active workspace to the one just restored, so the user actually
	-- lands in it rather than staying in (or being dropped into) another workspace.
	-- Backwards compatible: when `switch_workspace` is unset we fall back to the
	-- value of `spawn_in_workspace`, preserving the previous behaviour for callers
	-- that did neither. Pass `switch_workspace = false` to opt out explicitly.
	local should_switch = opts.switch_workspace
	if should_switch == nil then
		should_switch = opts.spawn_in_workspace
	end
	if workspace_state.workspace and workspace_state.workspace ~= "" then
		if should_switch then
			wezterm.mux.set_active_workspace(workspace_state.workspace)
		else
			-- Not switching (legacy `spawn_in_workspace = false`): keep the user in
			-- their current workspace but rename it to the restored name, so it no
			-- longer shows up as "default".
			wezterm.mux.rename_workspace(wezterm.mux.get_active_workspace(), workspace_state.workspace)
		end
	end

	wezterm.emit("resurrect.workspace_state.restore_workspace.finished")
end

---Returns a wezterm action that saves the current workspace state.
---Mirrors save_window_action() and save_tab_action() for use in custom key tables.
---@return table wezterm action
function pub.save_workspace_action()
	return wezterm.action_callback(function(win, pane)
		local current = wezterm.mux.get_active_workspace()

		local function do_save()
			local state = pub.get_workspace_state()
			state.user_named = true
			state_manager_mod.save_state(state)
		end

		if _named_workspaces[current] then
			do_save()
		elseif state_manager_mod.is_user_named(current, "workspace") then
			_named_workspaces[current] = true
			do_save()
		else
			win:perform_action(
				wezterm.action.PromptInputLine({
					description = "Enter a name for this workspace",
					action = wezterm.action_callback(function(_, _, name)
						if not name or name == "" then
							return
						end
						if state_manager_mod.is_user_named(name, "workspace") then
							wezterm.log_warn(
								"resurrect: workspace name '" .. name .. "' already in use — overwriting"
							)
						end
						if name ~= current then
							wezterm.mux.rename_workspace(current, name)
						end
						_named_workspaces[name] = true
						do_save()
					end),
				}),
				pane
			)
		end
	end)
end

---Returns the state of the current workspace
---@return workspace_state
function pub.get_workspace_state()
	local workspace_state = {
		workspace = wezterm.mux.get_active_workspace(),
		window_states = {},
	}
	for _, mux_win in ipairs(wezterm.mux.all_windows()) do
		if mux_win:get_workspace() == workspace_state.workspace then
			table.insert(workspace_state.window_states, window_state_mod.get_window_state(mux_win))
		end
	end
	return workspace_state
end

---Clears the named-workspace registry entry when a saved state is deleted via
---delete_action(). The workspace name itself is not changed. Called by fuzzy_loader.
---@param name string
function pub.on_state_deleted(name)
	_named_workspaces[name] = nil
end

return pub
