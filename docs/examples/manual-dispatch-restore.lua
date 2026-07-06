-- Full manual control over how each state type is restored, bypassing restore_action().
action = wezterm.action_callback(function(win, pane)
	resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id, label)
		local type = string.match(id, "^([^/]+)") -- match before '/'
		id = string.match(id, "([^/]+)$") -- match after '/'
		id = string.match(id, "(.+)%..+$") -- remove file extension
		local opts = {
			relative = true,
			restore_text = true,
			on_pane_restore = resurrect.pane_tree.default_on_pane_restore,
		}
		if type == "workspace" then
			local state = resurrect.state_manager.load_state(id, "workspace")
			-- Restores the windows into the saved workspace and switches you to it.
			-- Pass `spawn_in_workspace = false` to spawn into "default" without switching.
			resurrect.workspace_state.restore_workspace(state, opts)
		elseif type == "window" then
			local state = resurrect.state_manager.load_state(id, "window")
			resurrect.window_state.restore_window(pane:window(), state, opts)
		elseif type == "tab" then
			local state = resurrect.state_manager.load_state(id, "tab")
			local new_tab, new_pane = pane:window():spawn_tab({
				cwd = state.pane_tree and state.pane_tree.cwd or nil,
			})
			opts.pane = new_pane
			resurrect.tab_state.restore_tab(new_tab, state, opts)
		end
	end)
end)
