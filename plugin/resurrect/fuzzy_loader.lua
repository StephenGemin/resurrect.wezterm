local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local utils = require("resurrect.utils")
local pub = {}

---@alias fmt_fun fun(label: string): string
---@alias fuzzy_load_opts {title: string, description: string, fuzzy_description: string, is_fuzzy: boolean,
---ignore_workspaces: boolean, ignore_tabs: boolean, ignore_windows: boolean, fmt_window: fmt_fun, fmt_workspace: fmt_fun,
---fmt_tab: fmt_fun, fmt_date: fmt_fun, show_state_with_date: boolean, date_format: string, ignore_screen_width: boolean,
---name_truncature: string, min_filename_size: number}

---Default fuzzy loading options
---@type fuzzy_load_opts
pub.default_fuzzy_load_opts = {
	title = "Load State",
	description = "Select State to Load and press Enter = accept, Esc = cancel, / = filter",
	-- Branding lives on fuzzy_description, not description: with is_fuzzy = true the
	-- picker opens straight into fuzzy mode and only the fuzzy_description is shown.
	fuzzy_description = (wezterm.nerdfonts.md_backup_restore or "")
		.. "  resurrect.wezterm · select state to restore: ",
	is_fuzzy = true,
	ignore_workspaces = false,
	ignore_windows = false,
	ignore_tabs = false,
	ignore_screen_width = true,
	date_format = "%Y-%m-%d %H:%M",
	show_state_with_date = false,
	name_truncature = " " .. wezterm.nerdfonts.cod_ellipsis .. "  ",
	min_filename_size = 10,
	fmt_date = function(date)
		return wezterm.format({
			{ Foreground = { AnsiColor = "White" } },
			{ Text = date },
		})
	end,
	fmt_workspace = function(label)
		return wezterm.format({
			{ Foreground = { AnsiColor = "Green" } },
			{ Text = "󱂬 : " .. label:gsub("(.*)%.json(.*)", "%1%2") },
		})
	end,
	fmt_window = function(label)
		return wezterm.format({
			{ Foreground = { AnsiColor = "Yellow" } },
			{ Text = " : " .. label:gsub("(.*)%.json(.*)", "%1%2") },
		})
	end,
	fmt_tab = function(label)
		return wezterm.format({
			{ Foreground = { AnsiColor = "Red" } },
			{ Text = "󰓩 : " .. label:gsub("(.*)%.json(.*)", "%1%2") },
		})
	end,
}

-- Recursive JSON file finder using wezterm.run_child_process (no os.execute, no VBS).
-- Returns lines of "epoch filepath" for each .json file found.
---@param base_path string starting path from which the recursive search takes place
---@return string|nil
local function find_json_files_recursive(base_path)
	local success, stdout, stderr

	if utils.is_windows then
		-- Use PowerShell via run_child_process -- no visible window, no VBS temp files.
		-- PowerShell Get-ChildItem is available on all modern Windows.
		local ps_cmd = string.format(
			"Get-ChildItem -Path '%s' -Recurse -Filter '*.json' -File | "
				.. "ForEach-Object { "
				.. "[int][double]::Parse(($_.LastWriteTimeUtc - [datetime]'1970-01-01').TotalSeconds) "
				.. ".ToString() + ' ' + $_.FullName }",
			base_path:gsub("'", "''")
		)
		success, stdout, stderr = wezterm.run_child_process({
			"powershell.exe",
			"-NoProfile",
			"-NoLogo",
			"-Command",
			ps_cmd,
		})
	elseif utils.is_mac then
		success, stdout, stderr = wezterm.run_child_process({
			"sh",
			"-c",
			'find "' .. base_path:gsub('"', '\\"') .. '" -type f -name "*.json" -print0 | xargs -0 stat -f "%m %N"',
		})
	else
		success, stdout, stderr = wezterm.run_child_process({
			"sh",
			"-c",
			'find "'
				.. base_path:gsub('"', '\\"')
				.. '" -type f -name "*.json" -printf "%T@ %p\\n" | awk \'{split($1, a, "."); print a[1], $2}\'',
		})
	end

	if success then
		return stdout
	else
		local msg = stderr or "Failed to list state files"
		wezterm.log_error("resurrect: " .. msg)
		wezterm.emit("resurrect.error", msg)
		return nil
	end
end

local COL_GAP = "  "

-- Build the InputSelector choice list from the finder output: one row per saved
-- state, grouped workspace -> window -> tab and newest-saved first within each
-- group. When show_state_with_date is set, a trailing date column is aligned by
-- padding the single name column (InputSelector has no real multi-column API, so
-- widths are hand-measured on escape-stripped text).
---@param stdout string|nil
---@param opts table
---@return table
local function insert_choices(stdout, opts)
	local state_files = {}
	if stdout == nil then
		return state_files
	end

	local types = { "workspace", "window", "tab" }
	local files = { workspace = {}, window = {}, tab = {} }

	for line in stdout:gmatch("[^\n]+") do
		local epoch, type, file = line:match("%s*(%d+)%s+.+[/\\]([^/\\]+)[/\\]([^/\\]+%.json)$")
		if epoch and type and file and files[type] and not opts[string.format("ignore_%ss", type)] then
			table.insert(files[type], {
				id = type .. utils.separator .. file,
				epoch = tonumber(epoch),
				name = (file:gsub("%.json$", "")),
				fmt = opts[string.format("fmt_%s", type)],
			})
		end
	end

	-- Grouped workspace -> window -> tab, newest-first within each group.
	local ordered = {}
	for _, type in ipairs(types) do
		table.sort(files[type], function(a, b)
			return a.epoch > b.epoch
		end)
		for _, entry in ipairs(files[type]) do
			table.insert(ordered, entry)
		end
	end
	if #ordered == 0 then
		return state_files
	end

	-- Measure each entry's visible name width; the date is a single trailing column.
	local name_max = 0
	for _, e in ipairs(ordered) do
		e.name_w = utils.utf8len(utils.strip_format_esc_seq(e.fmt and e.fmt(e.name) or e.name))
		name_max = math.max(name_max, e.name_w)
		e.date = opts.show_state_with_date and os.date(opts.date_format, e.epoch) or ""
	end

	-- With a date column and a fixed window, cap width and truncate names to fit.
	if opts.show_state_with_date and not opts.ignore_screen_width then
		local total = name_max + utils.utf8len(COL_GAP) + utils.utf8len(ordered[1].date)
		local overflow = total - (utils.get_current_window_width() - 6)
		if overflow > 0 then
			name_max = math.max(name_max - overflow, opts.min_filename_size or 10)
		end
	end

	for _, e in ipairs(ordered) do
		local base = e.name
		if e.date ~= "" then
			-- Truncate the plain name toward the min size so the date column aligns.
			local target = name_max - (e.name_w - utils.utf8len(base)) -- minus the "<icon> : " prefix
			if utils.utf8len(base) > target then
				local pad = opts.name_truncature or "..."
				local reduction = #base - math.max(target - utils.utf8len(pad), opts.min_filename_size or 10)
				if reduction > 0 then
					base = utils.replace_center(base, reduction, pad)
				end
			end
		end

		local label = e.fmt and e.fmt(base) or base
		if e.date ~= "" then
			local name_vis = utils.utf8len(utils.strip_format_esc_seq(label))
			label = label
				.. string.rep(" ", math.max(name_max - name_vis, 0))
				.. COL_GAP
				.. (opts.fmt_date and opts.fmt_date(e.date) or e.date)
		end

		table.insert(state_files, { id = e.id, label = label })
	end

	return state_files
end

---Returns a wezterm action that opens a fuzzy picker and restores the chosen state.
---Dispatches automatically to workspace/window/tab restore based on the picked entry.
---Accepts the same restore_opts as restore_workspace/restore_window/restore_tab plus
---an optional `fuzzy_load_opts` field to customise the picker itself.
---
---Workspace and window restores always spawn a new GUI window and never touch the
---window the picker was invoked from, matching tmux-resurrect behaviour where restoring
---a session never modifies the current context. Tab restores always add to the current
---window, since a tab can't exist outside of one.
---@param opts? table restore_opts merged with optional `fuzzy_load_opts` sub-table
---@return table wezterm action
function pub.restore_action(opts)
	opts = opts or {}
	local picker_opts = opts.fuzzy_load_opts
	return wezterm.action_callback(function(win, pane)
		local tab_state = require("resurrect.tab_state")
		local state_manager = require("resurrect.state_manager")
		local restore_opts = utils.tbl_deep_extend("force", {
			relative = true,
			restore_text = true,
			on_pane_restore = tab_state.default_on_pane_restore,
		}, opts)
		restore_opts.fuzzy_load_opts = nil
		-- Force nil regardless of what opts contained: a workspace/window restore must
		-- never reuse the window the picker was invoked from. With opts.window nil,
		-- restore_workspace spawns a fresh window for window 1 too, the same as every
		-- other window in the saved state.
		restore_opts.window = nil
		restore_opts.current_window = nil

		-- One restorer per state type, so the picker callback is a flat lookup
		-- instead of an if/elseif chain.
		local restorers = {
			workspace = function(name)
				require("resurrect.workspace_state").restore_workspace(
					state_manager.load_state(name, "workspace"),
					restore_opts
				)
			end,
			window = function(name)
				local ws = state_manager.load_state(name, "window")
				local spawn_args = {}
				if ws.size then
					spawn_args.width = ws.size.cols
					spawn_args.height = ws.size.rows
				end
				if ws.tabs and ws.tabs[1] and ws.tabs[1].pane_tree then
					spawn_args.cwd = ws.tabs[1].pane_tree.cwd
				end
				local first_tab, first_pane, new_win = wezterm.mux.spawn_window(spawn_args)
				require("resurrect.window_state").restore_window(
					new_win,
					ws,
					utils.tbl_deep_extend("force", restore_opts, {
						tab = first_tab,
						pane = first_pane,
					})
				)
			end,
			tab = function(name)
				local ts = state_manager.load_state(name, "tab")
				local spawn_args = {}
				if ts.pane_tree and ts.pane_tree.cwd then
					spawn_args.cwd = ts.pane_tree.cwd
				end
				if ts.pane_tree and ts.pane_tree.domain then
					spawn_args.domain = { DomainName = ts.pane_tree.domain }
				end
				local new_tab, new_pane = pane:window():spawn_tab(spawn_args)
				tab_state.restore_tab(new_tab, ts, utils.tbl_deep_extend("force", restore_opts, { pane = new_pane }))
			end,
		}

		pub.fuzzy_load(win, pane, function(id, _label)
			local restorer = restorers[id:match("^([^/\\]+)")]
			local name = id:match("[/\\](.+)$")
			if restorer and name then
				restorer((name:gsub("%.json$", "")))
			end
		end, picker_opts)
	end)
end

---Returns a wezterm action that opens a fuzzy picker and deletes the chosen state file.
---@param opts? fuzzy_load_opts picker customisation (same as fuzzy_load opts)
---@return table wezterm action
function pub.delete_action(opts)
	local delete_opts = utils.tbl_deep_extend("force", {
		title = "Delete State",
		description = "Select a state to delete   (Enter = delete, Esc = cancel, / = filter)",
		-- Own prompt so the shared default doesn't say "restore" while deleting.
		fuzzy_description = (wezterm.nerdfonts.md_backup_restore or "")
			.. "  resurrect.wezterm · select state to delete: ",
		is_fuzzy = true,
	}, opts or {})
	return wezterm.action_callback(function(win, pane)
		pub.fuzzy_load(win, pane, function(id)
			local state_type = id:match("^([^/\\]+)")
			local raw = id:match("[/\\](.+)$")
			local name = raw and raw:gsub("%.json$", "")
			require("resurrect.state_manager").delete_state(id)
			if name then
				if state_type == "tab" then
					require("resurrect.tab_state").on_state_deleted(name)
				elseif state_type == "window" then
					require("resurrect.window_state").on_state_deleted(name)
				end
			end
		end, delete_opts)
	end)
end

---A fuzzy finder to restore saved state
---@param window MuxWindow
---@param pane Pane
---@param callback fun(id: string, label: string, save_state_dir: string)
---@param opts fuzzy_load_opts?
function pub.fuzzy_load(window, pane, callback, opts)
	wezterm.emit("resurrect.fuzzy_loader.fuzzy_load.start", window, pane)

	opts = utils.tbl_deep_extend("force", pub.default_fuzzy_load_opts, opts or {})

	local folder = require("resurrect.state_manager").save_state_dir

	-- Always use the recursive search function
	local stdout = find_json_files_recursive(folder)

	-- build the choice list for the InputSelector
	local state_files = insert_choices(stdout, opts)

	if #state_files == 0 then
		wezterm.log_error("resurrect: No existing state files to select")
		wezterm.emit("resurrect.error", "No existing state files to select")
	end

	-- even if the list is empty, user experience is better if we show an empty list
	window:perform_action(
		wezterm.action.InputSelector({
			action = wezterm.action_callback(function(_, _, id, label)
				if id and label then
					callback(id, label, require("resurrect.state_manager").save_state_dir)
				end
				wezterm.emit("resurrect.fuzzy_loader.fuzzy_load.finished", window, pane)
			end),
			title = opts.title,
			description = opts.description,
			fuzzy_description = opts.fuzzy_description,
			choices = state_files,
			fuzzy = opts.is_fuzzy,
		}),
		pane
	)
end

return pub
