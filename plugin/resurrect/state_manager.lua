local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local file_io = require("resurrect.file_io")
local utils = require("resurrect.utils")

local pub = {}
local _save_state_dir = utils.platform_default_state_dir()
-- pub.save_state_dir is part of the public API: fuzzy_loader reads it to locate
-- state files. Keep it in sync with _save_state_dir via change_state_save_dir —
-- do not remove or rename without updating fuzzy_loader.fuzzy_load.
pub.save_state_dir = _save_state_dir

---@param file_name string
---@param type string
---@param opt_name string?
---@return string
local function get_file_path(file_name, type, opt_name)
	if opt_name then
		file_name = opt_name
	end
	-- _save_state_dir carries a trailing separator (set by change_state_save_dir
	-- or defaulted by platform_default_state_dir), so the format string must not
	-- add one between it and `type` -- doing so yields a double separator.
	return string.format(
		"%s%s" .. utils.separator .. "%s.json",
		_save_state_dir,
		type,
		file_name:gsub("[" .. utils.separator .. ":%[%]?/*~!{}()&|;<>$`\"' \0]", "+")
	)
end

-- Roll the previous save at file_path to file_path.bak before it's overwritten,
-- so a degraded save (e.g. a partial restore saved back over a good snapshot)
-- doesn't permanently destroy the last known-good copy. write_state's atomic
-- temp-file+rename already protects against a torn write; this protects
-- against a successful-but-worse write.
---@param file_path string
local function rotate_backup(file_path)
	if not file_io.file_exists(file_path) then
		return
	end
	file_io.move_file(file_path, file_path .. ".bak")
end

---save state to a file
---@param state workspace_state | window_state | tab_state
---@param opt_name? string
function pub.save_state(state, opt_name)
	if state.window_states then
		utils.ensure_folder_exists(_save_state_dir .. "workspace")
		local fp = get_file_path(state.workspace, "workspace", opt_name)
		rotate_backup(fp)
		file_io.write_state(fp, state, "workspace")
	elseif state.tabs then
		utils.ensure_folder_exists(_save_state_dir .. "window")
		local fp = get_file_path(state.title, "window", opt_name)
		rotate_backup(fp)
		file_io.write_state(fp, state, "window")
	elseif state.pane_tree then
		utils.ensure_folder_exists(_save_state_dir .. "tab")
		local fp = get_file_path(state.title, "tab", opt_name)
		rotate_backup(fp)
		file_io.write_state(fp, state, "tab")
	end
end

---Reads a file with the state
---@param name string
---@param type string
---@return table
function pub.load_state(name, type)
	wezterm.emit("resurrect.state_manager.load_state.start", name, type)
	local json = file_io.load_json(get_file_path(name, type))
	if not json then
		local msg = "Invalid json: " .. get_file_path(name, type)
		wezterm.log_error("resurrect: " .. msg)
		wezterm.emit("resurrect.error", msg)
		return {}
	end
	wezterm.emit("resurrect.state_manager.load_state.finished", name, type)
	return json
end

-- Shared by periodic_save and event_driven_save: saves workspace state and
-- keeps current_state pointed at it, so both paths stay restore-on-startup-safe.
local function save_workspace()
	local workspace_state = require("resurrect.workspace_state").get_workspace_state()
	pub.save_state(workspace_state)
	pub.write_current_state(workspace_state.workspace, "workspace")
end

-- Shared by periodic_save (all gui windows) and event_driven_save (the single
-- window from the triggering event) to save user-named windows/tabs.
---@param mux_windows MuxWindow[]
---@param opts { save_windows: boolean?, save_tabs: boolean? }
local function save_named_windows_and_tabs(mux_windows, opts)
	for _, mux_win in ipairs(mux_windows) do
		if opts.save_windows then
			local title = mux_win:get_title()
			if title and title ~= "" and pub.is_user_named(title, "window") then
				local state = require("resurrect.window_state").get_window_state(mux_win)
				state.user_named = true
				pub.save_state(state)
			end
		end

		if opts.save_tabs then
			for _, mux_tab in ipairs(mux_win:tabs()) do
				local title = mux_tab:get_title()
				if title and title ~= "" and pub.is_user_named(title, "tab") then
					local state = require("resurrect.tab_state").get_tab_state(mux_tab)
					state.user_named = true
					pub.save_state(state)
				end
			end
		end
	end
end

---Saves the stater after interval in seconds
---@param opts? { interval_seconds: integer?, save_workspaces: boolean?, save_windows: boolean?, save_tabs: boolean? }
function pub.periodic_save(opts)
	if opts == nil then
		opts = { save_workspaces = true }
	end
	if opts.interval_seconds == nil then
		opts.interval_seconds = 60 * 15
	end
	wezterm.time.call_after(opts.interval_seconds, function()
		local ok, err = pcall(function()
			wezterm.emit("resurrect.state_manager.periodic_save.start", opts)
			if opts.save_workspaces then
				save_workspace()
			end

			if opts.save_windows or opts.save_tabs then
				local mux_windows = {}
				for _, gui_win in ipairs(wezterm.gui.gui_windows()) do
					table.insert(mux_windows, gui_win:mux_window())
				end
				save_named_windows_and_tabs(mux_windows, opts)
			end

			wezterm.emit("resurrect.state_manager.periodic_save.finished", opts)
		end)
		if not ok then
			wezterm.log_error("resurrect: periodic_save failed: " .. tostring(err))
			wezterm.emit("resurrect.error", "periodic_save failed: " .. tostring(err))
		end
		-- Always re-schedule, even after errors
		pub.periodic_save(opts)
	end)
end

---Saves the state whenever the pane or tab structure changes.
---More responsive than periodic_save: fires immediately on splits, new tabs,
---and closed panes rather than waiting for a timer.
---Also saves immediately when a GUI window loses OS focus (e.g. alt-tab to
---another application) -- set save_on_focus_loss = false to disable.
---Also supports an optional user variable trigger for shell-reported events
---such as directory changes (requires shell integration to send the OSC 1337
---SetUserVar sequence; see the README for details).
---@param opts? { save_workspaces: boolean?, save_windows: boolean?, save_tabs: boolean?, save_on_focus_loss: boolean?, user_var: string? }
local _event_driven_save_registered = false
function pub.event_driven_save(opts)
	if _event_driven_save_registered then
		wezterm.log_info("resurrect: event_driven_save already registered, skipping")
		return
	end
	_event_driven_save_registered = true

	opts = opts or {}
	if opts.save_workspaces == nil then
		opts.save_workspaces = true
	end
	if opts.save_on_focus_loss == nil then
		opts.save_on_focus_loss = true
	end

	local last_structure = {}

	local function do_save(window)
		local ok, err = pcall(function()
			wezterm.emit("resurrect.state_manager.event_driven_save.start", opts)

			if opts.save_workspaces then
				save_workspace()
			end

			if opts.save_windows or opts.save_tabs then
				save_named_windows_and_tabs({ window:mux_window() }, opts)
			end

			wezterm.emit("resurrect.state_manager.event_driven_save.finished", opts)
		end)
		if not ok then
			wezterm.log_error("resurrect: event_driven_save failed: " .. tostring(err))
			wezterm.emit("resurrect.error", "event_driven_save failed: " .. tostring(err))
		end
	end

	-- Save when the pane/tab structure changes (new split, new tab, closed pane).
	-- pane-focus-changed fires on every focus move, so we compare tab+pane counts
	-- and only save when the structure actually changes.
	wezterm.on("pane-focus-changed", function(window, _pane)
		local win_id = tostring(window:window_id())
		local tabs = window:mux_window():tabs()
		local pane_count = 0
		for _, tab in ipairs(tabs) do
			pane_count = pane_count + #tab:panes()
		end
		local sig = #tabs .. ":" .. pane_count
		if last_structure[win_id] ~= sig then
			last_structure[win_id] = sig
			do_save(window)
		end
	end)

	-- Save the instant a GUI window loses OS focus (e.g. alt-tab to another app).
	-- window-focus-changed fires on both gain and loss for the window whose focus
	-- state changed, and window:is_focused() reflects the new state at call time,
	-- so no cross-window bookkeeping is needed to distinguish "this window lost
	-- focus" from "a different window gained it" -- that never fires this event
	-- for this window. last_focus_state still tracks per-window state, purely to
	-- collapse repeated same-state firings into a single save. The debounce below
	-- caps this to one save per FOCUS_LOSS_DEBOUNCE_SECONDS regardless of window
	-- count, since do_save can shell out synchronously to an encryption subprocess
	-- and rapid alt-tabbing shouldn't spawn one on every bounce.
	if opts.save_on_focus_loss then
		local FOCUS_LOSS_DEBOUNCE_SECONDS = 10
		local last_focus_state = {}
		local last_focus_loss_save = 0
		wezterm.on("window-focus-changed", function(window, _pane)
			local win_id = tostring(window:window_id())
			local ok, is_focused_or_err = pcall(function()
				return window:is_focused()
			end)
			if not ok then
				-- window's GUI-side channel can already be closed by the time this
				-- event fires (e.g. mid-teardown/mid-creation during a workspace
				-- switch) -- is_focused() does a synchronous round-trip to the GUI
				-- thread and errors instead of returning. This is an expected,
				-- handled race (log_info, not log_error) -- skip this event rather
				-- than letting it crash to the wezterm log.
				wezterm.log_info(
					"resurrect: skipped window-focus-changed for window "
						.. win_id
						.. ": is_focused() failed, likely because the window's GUI-side"
						.. " channel was already closed (window mid-teardown/creation): "
						.. tostring(is_focused_or_err)
				)
				return
			end
			local is_focused = is_focused_or_err
			-- Unseen (nil) is treated as "assume was focused," so the very first
			-- alt-tab-away still triggers a save instead of silently no-oping.
			if last_focus_state[win_id] ~= false and not is_focused then
				local now = os.time()
				if now - last_focus_loss_save >= FOCUS_LOSS_DEBOUNCE_SECONDS then
					last_focus_loss_save = now
					wezterm.log_info("resurrect: saved (focus-loss)")
					do_save(window)
				end
			end
			last_focus_state[win_id] = is_focused
		end)
	end

	-- Optional: also save when the shell reports a user-defined variable change.
	-- Useful for saving on directory change. Example shell integration (zsh/bash):
	--   precmd() { printf "\033]1337;SetUserVar=WEZTERM_SAVE=%s\007" "$(printf 1 | base64)"; }
	if opts.user_var then
		wezterm.on("user-var-changed", function(window, _pane, name, _value)
			if name == opts.user_var then
				do_save(window)
			end
		end)
	end
end

---Writes the current state name and type
---@param name string
---@param type string
---@return boolean
---@return string|nil
function pub.write_current_state(name, type)
	local file_path = _save_state_dir .. "current_state"
	local suc, err = file_io.write_file(file_path, string.format("%s\n%s", name, type))
	return suc, err
end

---callback for resurrecting workspaces on startup
---@return boolean
---@return string|nil
function pub.resurrect_on_gui_startup()
	local file_path = _save_state_dir .. "current_state"
	local suc, err = pcall(function()
		local file = io.open(file_path, "r")
		if not file then
			wezterm.log_info("resurrect: no current_state file at " .. file_path .. "; skipping startup restore")
			return
		end
		local name = file:read("*line")
		local state_type = file:read("*line")
		file:close()
		if state_type == "workspace" then
			wezterm.log_info("resurrect: restoring workspace '" .. tostring(name) .. "' on gui-startup")
			require("resurrect.workspace_state").restore_workspace(pub.load_state(name, state_type), {
				spawn_in_workspace = true,
				relative = true,
				restore_text = true,
				on_pane_restore = require("resurrect.tab_state").default_on_pane_restore,
			})
			wezterm.mux.set_active_workspace(name)
		else
			wezterm.log_info(
				"resurrect: current_state at "
					.. file_path
					.. " has type '"
					.. tostring(state_type)
					.. "', not 'workspace'; skipping startup restore"
			)
		end
	end)
	if not suc then
		wezterm.log_error("resurrect: gui_startup restore failed: " .. tostring(err))
		wezterm.emit("resurrect.error", "gui_startup restore failed: " .. tostring(err))
	end
	return suc, err
end

---Returns true if the saved state for name/type was explicitly user-named.
---Does a quiet file read with no error events — safe to call when the file may not exist yet.
---@param name string
---@param type string
---@return boolean
function pub.is_user_named(name, type)
	local path = get_file_path(name, type)
	local json = file_io.load_json(path)
	return json ~= nil and json.user_named == true
end

---@param file_path string
function pub.delete_state(file_path)
	wezterm.emit("resurrect.state_manager.delete_state.start", file_path)
	-- Path confinement: reject traversal attempts, absolute paths, and
	-- non-JSON files to prevent arbitrary file deletion.
	if file_path:find("%.%.") then
		wezterm.log_error("resurrect: delete_state rejected path with '..': " .. file_path)
		wezterm.emit("resurrect.error", "Invalid path: directory traversal not allowed")
		return
	end
	if file_path:match("^[/\\]") or file_path:match("^%a:") then
		wezterm.log_error("resurrect: delete_state rejected absolute path: " .. file_path)
		wezterm.emit("resurrect.error", "Invalid path: absolute paths not allowed")
		return
	end
	if not file_path:match("%.json$") then
		wezterm.log_error("resurrect: delete_state rejected non-JSON path: " .. file_path)
		wezterm.emit("resurrect.error", "Invalid path: only .json files can be deleted")
		return
	end
	local path = _save_state_dir .. file_path
	local success = os.remove(path)
	if not success then
		wezterm.emit("resurrect.error", "Failed to delete state: " .. path)
		wezterm.log_error("Failed to delete state: " .. path)
	end
	wezterm.emit("resurrect.state_manager.delete_state.finished", file_path)
end

--- Merges user-supplied options with default options
--- @param user_opts encryption_opts
function pub.set_encryption(user_opts)
	require("resurrect.file_io").set_encryption(user_opts)
end

---Changes the directory to save the state to
---@param directory string
function pub.change_state_save_dir(directory)
	_save_state_dir = directory
	pub.save_state_dir = directory
end

function pub.set_max_nlines(max_nlines)
	require("resurrect.pane_tree").max_nlines = max_nlines
end

return pub
