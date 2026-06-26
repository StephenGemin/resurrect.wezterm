local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local tab_state_mod = require("resurrect.tab_state")

local pub = {}

---@param tab MuxTab
---@param tab_to_keep MuxTab
local function close_all_other_tabs(window, tab_to_keep)
	for _, t in ipairs(window:tabs()) do
		if t:tab_id() ~= tab_to_keep:tab_id() then
			t:activate()
			wezterm.sleep_ms(100)
			window:perform_action(wezterm.action.CloseCurrentTab({ confirm = false }), t:active_pane())
		end
	end
end

---@param window MuxWindow
---@return window_state
function pub.get_window_state(window)
	local tabs = {}
	for _, tab in ipairs(window:tabs()) do
		table.insert(tabs, tab_state_mod.get_tab_state(tab))
	end
	local window_state = {
		title = window:get_title(),
		tabs = tabs,
		size = window:active_tab():get_size(),
	}
	return window_state
end

---@param window MuxWindow
---@param window_state window_state
---@param opts? restore_opts
function pub.restore_window(window, window_state, opts)
	if opts == nil then
		opts = {}
	end

	window:set_title(window_state.title)

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

		if tab_state.is_zoomed then
			tab:active_pane():toggle_zoom()
		end

		if tab_state.is_active then
			active_tab = tab
		end
	end

	if active_tab then
		active_tab:activate()
	end
end

---@return Action
function pub.save_window_action()
	return wezterm.action_callback(function(window, _)
		local mux_window = window:mux_window()
		local title = mux_window:get_title()
		if title == nil or title == "" then
			window:perform_action(
				wezterm.action.PromptInputLine({
					description = "Enter window title",
					action = wezterm.action_callback(function(_, _, line)
						if line then
							mux_window:set_title(line)
							require("resurrect.state_manager").save_state(pub.get_window_state(mux_window))
						end
					end),
				}),
				window:active_pane()
			)
		else
			require("resurrect.state_manager").save_state(pub.get_window_state(mux_window))
		end
	end)
end

return pub
