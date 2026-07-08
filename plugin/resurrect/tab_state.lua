local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local pane_tree_mod = require("resurrect.pane_tree")
local state_manager_mod = require("resurrect.state_manager")
local pub = {}

local _named_tabs = {} -- {[tab_id: integer] = name: string}

---Total column span of a subtree: its own width plus the width of everything to
---its right. Bottom-children share their parent's column, so they add no width
---and are not followed here. Used so a split allocates the whole right subtree
---its combined width rather than only the immediate child's (chains of
---horizontal splits would otherwise under-allocate the far side and drift).
---@param node pane_tree?
---@return integer
local function span_width(node)
	if node == nil then
		return 0
	end
	return node.width + span_width(node.right)
end

---Total row span of a subtree: its own height plus the height of everything
---below it. Right-children share their parent's row, so they add no height.
---@param node pane_tree?
---@return integer
local function span_height(node)
	if node == nil then
		return 0
	end
	return node.height + span_height(node.bottom)
end

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

		local right = pane_tree.right
		local bottom = pane_tree.bottom

		-- Each split allocates the child's whole subtree span, not just the
		-- immediate child's width/height, so chains of same-direction splits keep
		-- their proportions instead of the far side drifting narrower each level.
		local function split_right()
			local split_args = { direction = "Right", cwd = right.cwd }
			local right_span = span_width(right)
			if opts.relative then
				split_args.size = right_span / (pane_tree.width + right_span)
			elseif opts.absolute then
				split_args.size = right_span
			end
			right.pane = pane:split(split_args)
		end

		local function split_bottom()
			local split_args = { direction = "Bottom", cwd = bottom.cwd }
			local bottom_span = span_height(bottom)
			if opts.relative then
				split_args.size = bottom_span / (pane_tree.height + bottom_span)
			elseif opts.absolute then
				split_args.size = bottom_span
			end
			bottom.pane = pane:split(split_args)
		end

		-- With both children, the split whose subtree spans this node's full
		-- region -- the guillotine cut that runs edge to edge -- must be made
		-- first, so the other cut lands inside the remaining piece rather than
		-- carving across the whole node. The right subtree spans the full height
		-- exactly when it extends below this node's own cell; otherwise the
		-- bottom subtree is the full-width band and goes first. A fixed order
		-- can't satisfy both, because create_pane_tree encodes a 2x2 grid with
		-- the far corner under either child depending on the exact divider
		-- coordinates.
		if right and bottom then
			if span_height(right) > pane_tree.height then
				split_right()
				split_bottom()
			else
				split_bottom()
				split_right()
			end
		elseif right then
			split_right()
		elseif bottom then
			split_bottom()
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

	-- Wrapped in pcall so a thrown error partway through (bad split args, a
	-- malformed saved pane_tree, etc.) surfaces as resurrect.error instead of
	-- aborting silently with .start fired and no .finished or error signal.
	local ok, err = pcall(function()
		if opts.pane then
			tab_state.pane_tree.pane = opts.pane
			-- Only needed when genuinely reusing an already-running pane (see
			-- workspace_state.restore_workspace's active-pane reuse case). Panes spawned
			-- fresh already have the right cwd from their spawn args; sending `cd` there
			-- is a redundant command that ends up baked into scrollback and gets
			-- replayed + re-saved on every future restore.
			if opts.pane_needs_cd and tab_state.pane_tree.cwd and tab_state.pane_tree.cwd ~= "" then
				opts.pane:send_text("cd " .. wezterm.shell_join_args({ tab_state.pane_tree.cwd }) .. "\r\n")
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
