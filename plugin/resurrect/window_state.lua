local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local tab_state_mod = require("resurrect.tab_state")
local state_manager_mod = require("resurrect.state_manager")
local pub = {}

local _named_windows = {} -- {[window_id: integer] = name: string}

---Returns the state of the window
---@param window MuxWindow
---@return window_state
function pub.get_window_state(window)
	local window_state = {
		title = window:get_title(),
		tabs = {},
	}

	local tabs = window:tabs_with_info()

	for i, tab in ipairs(tabs) do
		local tab_state = tab_state_mod.get_tab_state(tab.tab)
		tab_state.is_active = tab.is_active
		window_state.tabs[i] = tab_state
	end

	window_state.size = tabs[1].tab:get_size()

	return window_state
end

---Force closes all other tabs in the window but one
---@param window MuxWindow
---@param tab_to_keep MuxTab
local function close_all_other_tabs(window, tab_to_keep)
	for _, tab in ipairs(window:tabs()) do
		if tab:tab_id() ~= tab_to_keep:tab_id() then
			tab:activate()
			window
				:gui_window()
				:perform_action(wezterm.action.CloseCurrentTab({ confirm = false }), window:active_pane())
		end
	end
end

---restore window state
---@param window MuxWindow
---@param window_state window_state
---@param opts? restore_opts
function pub.restore_window(window, window_state, opts)
	wezterm.emit("resurrect.window_state.restore_window.start")
	if opts == nil then
		opts = {}
	end

	if window_state.title then
		window:set_title(window_state.title)
	end

	local active_tab
	for i, tab_state in ipairs(window_state.tabs) do
		local tab
		if i == 1 and opts.tab then
			tab = opts.tab
		else
			local spawn_tab_args = { cwd = tab_state.pane_tree.cwd }
			if tab_state.pane_tree.domain then
				spawn_tab_args.domain = { DomainName = tab_state.pane_tree.domain }
			end
			tab, opts.pane = window:spawn_tab(spawn_tab_args)
		end

		if i == 1 and opts.close_open_tabs then
			close_all_other_tabs(window, tab)
		end

		tab_state_mod.restore_tab(tab, tab_state, opts)
		if tab_state.is_active then
			active_tab = tab
		end

		if tab_state.is_zoomed then
			tab:set_zoomed(true)
		end
	end

	if active_tab then
		active_tab:activate()
	end
	wezterm.emit("resurrect.window_state.restore_window.finished")
end

function pub.save_window_action()
	return wezterm.action_callback(function(win, pane)
		local mux_win = win:mux_window()
		local win_id = mux_win:window_id()

		local function do_save(mw)
			local state = pub.get_window_state(mw)
			state.user_named = true
			state_manager_mod.save_state(state)
		end

		if _named_windows[win_id] then
			do_save(mux_win)
		elseif state_manager_mod.is_user_named(mux_win:get_title(), "window") then
			_named_windows[win_id] = mux_win:get_title()
			do_save(mux_win)
		else
			win:perform_action(
				wezterm.action.PromptInputLine({
					description = "Enter a name for this window",
					action = wezterm.action_callback(function(window, _, name)
						if not name or name == "" then
							return
						end
						local mw = window:mux_window()
						if state_manager_mod.is_user_named(name, "window") then
							wezterm.log_warn("resurrect: window name '" .. name .. "' already in use — overwriting")
						end
						_named_windows[mw:window_id()] = name
						mw:set_title(name)
						do_save(mw)
					end),
				}),
				pane
			)
		end
	end)
end

---Clears the named-window registry entry and resets the window title when a
---saved state is deleted via delete_action(). Called by fuzzy_loader.
---@param name string
function pub.on_state_deleted(name)
	for id, stored in pairs(_named_windows) do
		if stored == name then
			_named_windows[id] = nil
			break
		end
	end
	for _, mux_win in ipairs(wezterm.mux.all_windows()) do
		if mux_win:get_title() == name then
			mux_win:set_title("")
			return
		end
	end
end

return pub
