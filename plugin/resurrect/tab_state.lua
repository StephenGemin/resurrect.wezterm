local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local pane_tree_mod = require("resurrect.pane_tree")
local state_manager_mod = require("resurrect.state_manager")
local pub = {}

local _named_tabs = {} -- {[tab_id: integer] = name: string}

---Function used to split panes when mapping over the pane_tree
---@param opts restore_opts
---@return fun(acc: {active_pane: Pane, is_zoomed: boolean}, pane_tree: pane_tree): {active_pane: Pane, is_zoomed: boolean}
local function make_splits(opts)
	if opts == nil then
		opts = {}
	end

	return function(acc, pane_tree)
		local pane = pane_tree.pane

		if opts.on_pane_restore then
			opts.on_pane_restore(pane_tree)
		end

		local bottom = pane_tree.bottom
		if bottom then
			local split_args = { direction = "Bottom", cwd = bottom.cwd }
			if opts.relative then
				split_args.size = bottom.height / (pane_tree.height + bottom.height)
			elseif opts.absolute then
				split_args.size = bottom.height
			end

			bottom.pane = pane:split(split_args)
		end

		local right = pane_tree.right
		if right then
			local split_args = { direction = "Right", cwd = right.cwd }
			if opts.relative then
				split_args.size = right.width / (pane_tree.width + right.width)
			elseif opts.absolute then
				split_args.size = right.width
			end

			right.pane = pane:split(split_args)
		end

		if pane_tree.is_active then
			acc.active_pane = pane_tree.pane
		end

		if pane_tree.is_zoomed then
			acc.is_zoomed = true
		end

		return acc
	end
end

---creates and returns the state of the tab
---@param tab MuxTab
---@return tab_state
function pub.get_tab_state(tab)
	local panes = tab:panes_with_info()

	local function is_zoomed()
		for _, pane in ipairs(panes) do
			if pane.is_zoomed then
				return true
			end
		end
		return false
	end

	local tab_state = {
		title = tab:get_title(),
		is_zoomed = is_zoomed(),
		pane_tree = pane_tree_mod.create_pane_tree(panes),
	}

	return tab_state
end

---Force closes all other tabs in the window but one
---@param tab MuxTab
---@param pane_to_keep Pane
local function close_all_other_panes(tab, pane_to_keep)
	for _, pane in ipairs(tab:panes()) do
		if pane:pane_id() ~= pane_to_keep:pane_id() then
			pane:activate()
			tab:window():gui_window():perform_action(wezterm.action.CloseCurrentPane({ confirm = false }), pane)
		end
	end
end

---restore a tab
---@param tab MuxTab
---@param tab_state tab_state
---@param opts restore_opts
function pub.restore_tab(tab, tab_state, opts)
	wezterm.emit("resurrect.tab_state.restore_tab.start")
	state_manager_mod.extend_save_suppression()

	-- Wrapped in pcall so a thrown error partway through (bad split args, a
	-- malformed saved pane_tree, etc.) surfaces as resurrect.error instead of
	-- aborting silently with .start fired and no .finished or error signal.
	local ok, err = pcall(function()
		if opts.pane then
			tab_state.pane_tree.pane = opts.pane
			-- Only the genuinely reused pane (workspace_state's active-pane
			-- reuse, flagged by pane_needs_cd) had a shell running before the
			-- replay was injected -- its prompt and the cd exchange below
			-- interleave with the replay, so restore_baseline must not learn a
			-- prompt exemplar from a prefix match there. Roots that arrive via
			-- opts.pane from spawn_tab/spawn_window are fresh shells with the
			-- right cwd from their spawn args and learn exemplars normally.
			-- The cd command is recorded as a marker so restore_baseline can
			-- still measure the prompt block painted below its echo. Never
			-- persisted: get_tab_state rebuilds trees from live panes, so
			-- these flags cannot leak into state files.
			if opts.pane_needs_cd then
				tab_state.pane_tree.reused_pane = true
				if tab_state.pane_tree.cwd and tab_state.pane_tree.cwd ~= "" then
					local cd_cmd = "cd " .. wezterm.shell_join_args({ tab_state.pane_tree.cwd })
					tab_state.pane_tree.cd_marker = cd_cmd
					opts.pane:send_text(cd_cmd .. "\r\n")
				end
			end
			opts.pane_needs_cd = nil
		else
			local split_args = { cwd = tab_state.pane_tree.cwd }
			if tab_state.pane_tree.domain then
				split_args.domain = { DomainName = tab_state.pane_tree.domain }
			end
			local new_pane = tab:active_pane():split(split_args)
			tab_state.pane_tree.pane = new_pane
		end

		if opts.close_open_panes then
			close_all_other_panes(tab, tab_state.pane_tree.pane)
		end

		if tab_state.title then
			tab:set_title(tab_state.title)
		end

		local acc = pane_tree_mod.fold(tab_state.pane_tree, { is_zoomed = false }, make_splits(opts))
		-- acc.active_pane is only set if some node in the saved tree has is_active
		-- true; a malformed or hand-edited state file can omit that, which would
		-- otherwise crash the whole restore here.
		if acc.active_pane then
			acc.active_pane:activate()
		end
	end)

	if not ok then
		wezterm.log_error("resurrect: restore_tab failed: " .. tostring(err))
		wezterm.emit("resurrect.error", "restore_tab failed: " .. tostring(err))
		return
	end

	wezterm.emit("resurrect.tab_state.restore_tab.finished")
end

function pub.save_tab_action()
	return wezterm.action_callback(function(win, pane)
		local tab = pane:tab()
		local tab_id = tab:tab_id()

		local function do_save(t)
			local state = pub.get_tab_state(t)
			state.user_named = true
			state_manager_mod.save_state(state)
		end

		if _named_tabs[tab_id] then
			do_save(tab)
		elseif state_manager_mod.is_user_named(tab:get_title(), "tab") then
			_named_tabs[tab_id] = tab:get_title()
			do_save(tab)
		else
			win:perform_action(
				wezterm.action.PromptInputLine({
					description = "Enter a name for this tab",
					action = wezterm.action_callback(function(_, callback_pane, name)
						if not name or name == "" then
							return
						end
						local t = callback_pane:tab()
						if state_manager_mod.is_user_named(name, "tab") then
							wezterm.log_warn("resurrect: tab name '" .. name .. "' already in use — overwriting")
						end
						_named_tabs[t:tab_id()] = name
						t:set_title(name)
						do_save(t)
					end),
				}),
				pane
			)
		end
	end)
end

---Backward-compat alias: this was the original implementation (function moved to pane_tree.lua).
---Kept so existing configs referencing resurrect.tab_state.default_on_pane_restore keep working.
pub.default_on_pane_restore = pane_tree_mod.default_on_pane_restore

---Clears the named-tab registry entry and resets the tab title when a saved
---state is deleted via delete_action(). Called by fuzzy_loader.
---@param name string
function pub.on_state_deleted(name)
	for id, stored in pairs(_named_tabs) do
		if stored == name then
			_named_tabs[id] = nil
			break
		end
	end
	for _, mux_win in ipairs(wezterm.mux.all_windows()) do
		for _, tab in ipairs(mux_win:tabs()) do
			if tab:get_title() == name then
				tab:set_title("")
				return
			end
		end
	end
end

return pub
