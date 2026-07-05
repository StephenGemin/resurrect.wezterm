local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm

local utils = {}

utils.is_windows = wezterm.target_triple:find("windows")
utils.is_mac = wezterm.target_triple:find("darwin")
utils.separator = utils.is_windows and "\\" or "/"

---Returns the platform-appropriate directory for persisting resurrect.wezterm state.
---Respects XDG_STATE_HOME on Linux; uses Application Support on macOS;
---uses %APPDATA% on Windows. Always ends with the platform path separator.
---@return string
function utils.platform_default_state_dir()
	local home = wezterm.home_dir
	if utils.is_windows then
		local appdata = os.getenv("APPDATA") or (home .. "\\AppData\\Roaming")
		return appdata .. "\\wezterm\\resurrect\\"
	elseif utils.is_mac then
		return home .. "/Library/Application Support/wezterm/resurrect/"
	else
		local xdg = os.getenv("XDG_STATE_HOME") or (home .. "/.local/state")
		return xdg .. "/wezterm/resurrect/"
	end
end

-- Helper function to remove formatting esc sequences in the string
---@param str string
---@return string
function utils.strip_format_esc_seq(str)
	local clean_str, _ = str:gsub(string.char(27) .. "%[[^m]*m", "")
	return clean_str
end

-- Trailing blank rows in captured scrollback often end in a color/SGR escape
-- sequence (e.g. a trailing reset) even though the row itself renders empty,
-- so a plain trailing-whitespace strip leaves them in place. Shell integration
-- (OSC 133/OSC 7) can also leave an OSC sequence trailing the last row; an
-- unrecognized trailing token of either kind blocks the strip loop and leaves
-- every blank row above it in place. Strip whitespace, CSI, and OSC sequences
-- alternately from the end until nothing matches, so idle rows on screen at
-- save time don't get replayed -- and re-saved -- on every subsequent restore.
local ESC = string.char(27)
local BEL = string.char(7)
---@param text string
---@return string
function utils.strip_trailing_blank_rows(text)
	local stripped = true
	while stripped do
		stripped = false
		local without_ws, ws_count = text:gsub("%s+$", "")
		if ws_count > 0 then
			text = without_ws
			stripped = true
		end
		-- Final byte is any of "@"-"~" (0x40-0x7E) per the CSI grammar, not just
		-- letters -- e.g. private-mode sequences end in "h"/"l", SGR ends in "m".
		local without_csi, csi_count = text:gsub(ESC .. "%[[^@-~]*[@-~]$", "")
		if csi_count > 0 then
			text = without_csi
			stripped = true
		end
		-- OSC has two legal terminators (BEL, or ST = ESC "\\"); both occur in
		-- the wild, so both passes are needed.
		local without_osc_bel, osc_bel_count = text:gsub(ESC .. "%][^" .. BEL .. "]*" .. BEL .. "$", "")
		if osc_bel_count > 0 then
			text = without_osc_bel
			stripped = true
		end
		local without_osc_st, osc_st_count = text:gsub(ESC .. "%][^" .. ESC .. "]*" .. ESC .. "\\$", "")
		if osc_st_count > 0 then
			text = without_osc_st
			stripped = true
		end
		-- Escape sequences with intermediate bytes (0x20-0x2F) and a final byte,
		-- e.g. the ESC ( B charset designation that get_lines_as_escapes emits at
		-- the start of every row; a trailing one otherwise blocks the strip loop
		-- just like an unrecognized CSI/OSC would.
		local without_esc, esc_count = text:gsub(ESC .. "[ -/]+[0-~]$", "")
		if esc_count > 0 then
			text = without_esc
			stripped = true
		end
	end
	return text
end

---Capture a pane's scrollback as escape-encoded text, capped at max_nlines
---rows and stripped of trailing blank rows. Both the save-time capture and
---restore_baseline's settle snapshot must go through this same path so their
---outputs are byte-comparable.
---@param pane Pane
---@param max_nlines integer
---@return string
function utils.capture_pane_text(pane, max_nlines)
	local nlines = pane:get_dimensions().scrollback_rows
	if nlines > max_nlines then
		nlines = max_nlines
	end
	return utils.strip_trailing_blank_rows(pane:get_lines_as_escapes(nlines))
end

---Remove every escape sequence (CSI, OSC with either terminator, and
---intermediate-byte sequences such as the ESC ( B charset designation)
---anywhere in the string -- strip_format_esc_seq only handles SGR. Used to
---compare what captured rows render as, independent of coloring.
---@param str string
---@return string
function utils.strip_esc_seqs(str)
	local s = str:gsub(ESC .. "%[[^@-~]*[@-~]", "")
	s = s:gsub(ESC .. "%][^" .. BEL .. ESC .. "]*" .. BEL, "")
	s = s:gsub(ESC .. "%][^" .. BEL .. ESC .. "]*" .. ESC .. "\\", "")
	s = s:gsub(ESC .. "[ -/]+[0-~]", "")
	return s
end

---What a captured row renders as: escape sequences removed and surrounding
---whitespace (including any \r) trimmed.
---@param row string
---@return string
function utils.row_plaintext(row)
	return (utils.strip_esc_seqs(row):gsub("^%s*(.-)%s*$", "%1"))
end

---Number of rows in captured text: 0 for empty text, newline count + 1
---otherwise, so appending one row always increases the count by one.
---@param text string
---@return integer
function utils.count_text_rows(text)
	if text == "" then
		return 0
	end
	local _, n = text:gsub("\n", "")
	return n + 1
end

---The final row of captured text (everything after the last newline).
---@param text string
---@return string
function utils.last_row(text)
	return text:match("[^\n]*$") or ""
end

---Drop the last n rows and the newlines binding them; "" when n covers the
---whole text. Rows above the drop are preserved byte-identically, except
---that the \r left dangling by a dropped \r\n separator is removed too.
---@param text string
---@param n integer
---@return string
function utils.strip_last_rows(text, n)
	for _ = 1, n do
		local without = text:match("^(.*)\n[^\n]*$")
		if not without then
			return ""
		end
		text = without
	end
	return (text:gsub("\r$", ""))
end

---Extract the lowercased base command name from a process name/path,
---stripping any directory prefix and a Windows .exe suffix.
---@param proc_name string|nil
---@return string
function utils.base_name_of(proc_name)
	proc_name = proc_name or ""
	local base_name = proc_name:match("[/\\]?([^/\\]+)$") or proc_name
	return base_name:gsub("%.exe$", ""):lower()
end

-- Shells whose presence in the foreground-process slot means the pane is
-- sitting at (or momentarily back at) its prompt. Used two ways: a stale
-- alt-screen read that reports one of these has already handed the pty back
-- to the shell (fall through to text capture instead of persisting a bogus
-- process), and a text capture whose foreground process is one of these ends
-- in a live prompt block that a restore's fresh shell will repaint (safe for
-- restore_baseline to strip).
utils.COMMON_SHELLS = {
	bash = true,
	zsh = true,
	sh = true,
	dash = true,
	fish = true,
	ksh = true,
	tcsh = true,
	csh = true,
	pwsh = true,
	powershell = true,
	cmd = true,
	nu = true,
}

-- getting screen dimensions
---@return number
function utils.get_current_window_width()
	local windows = wezterm.gui.gui_windows()
	for _, window in ipairs(windows) do
		if window:is_focused() then
			return window:active_tab():get_size().cols
		end
	end
	return 80
end

-- replace the center of a string with another string
---@param str string string to be modified
---@param len number length to be removed from the middle of str
---@param pad string string that must be inserted in place of the missing part of str
function utils.replace_center(str, len, pad)
	local mid = #str // 2
	local start = mid - (len // 2)
	return str:sub(1, start) .. pad .. str:sub(start + len + 1)
end

-- returns the length of a utf8 string
---@param str string
---@return number
function utils.utf8len(str)
	local _, len = str:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
	return len
end

-- Execute a command array and return its stdout.
-- Uses wezterm.run_child_process to avoid shell injection and cmd.exe flashes.
---@param cmd_args string[] array of command and arguments
---@return boolean success result
---@return string|nil output
function utils.exec(cmd_args)
	local success, stdout, stderr = wezterm.run_child_process(cmd_args)
	if success then
		return true, stdout
	else
		return false, stderr or "Command failed"
	end
end

-- Legacy wrapper: execute a shell command string via sh -c (Unix) or cmd /c (Windows).
-- Prefer utils.exec() with argument arrays for new code.
---@param cmd string command
---@return boolean success result
---@return string|nil error
function utils.execute(cmd)
	if utils.is_windows then
		return utils.exec({ "cmd.exe", "/c", cmd })
	else
		return utils.exec({ "sh", "-c", cmd })
	end
end

-- Shell-safe wrapper around mkdir for a single already-assembled path segment.
-- On Unix, single-quote wrapping is used so that spaces and most metacharacters
-- are inert; embedded single quotes are escaped with the '\'' idiom.
-- On Windows, " is not a valid NTFS filename character so we validate and reject
-- rather than attempt to escape it; remaining quoting via double-quotes is safe.
local function shell_mkdir(path)
	if utils.is_windows then
		if path:find('"') then
			return false
		end
		return os.execute('mkdir "' .. path .. '"')
	else
		-- -p: create all missing parents in one shot and succeed if dir already exists.
		-- wezterm.run_child_process passes path as a direct argv element (no shell),
		-- so special characters in path cannot cause injection.
		local success, _, _ = wezterm.run_child_process({ "mkdir", "-p", path })
		return success
	end
end

-- Probe-write check: attempts to create and immediately remove a temp file
-- inside path. More reliable than os.rename on Windows, where open handles
-- held by WezTerm itself cause os.rename(dir, dir) to return nil even when
-- the directory exists and is fully usable.
-- A unique suffix from tostring({}) (table address) avoids collisions across
-- concurrent processes or calls.
local function dir_is_accessible(path)
	local probe = path .. utils.separator .. ".resurrect_probe_" .. tostring({}):gsub("[^%w]", "")
	local f = io.open(probe, "w")
	if f then
		f:close()
		os.remove(probe)
		return true
	end
	return false
end

-- Create the folder if it does not exist.
-- `mkdir -p` (Unix) and cmd's `mkdir` (Windows) both create all missing
-- parent directories in a single call, so only the leaf directory itself
-- needs to be checked/created. Walking and probe-writing every ancestor
-- (the previous approach) is unnecessary overhead, and on Windows it also
-- re-triggers shell_mkdir -- a visible cmd.exe flash -- on every launch for
-- any ancestor the current user can't write to (e.g. C:\Users on a
-- non-admin account), even though the leaf directory already exists.
-- Drive-relative paths (e.g. C:foo\bar) are normalised to absolute so cmd's
-- mkdir doesn't interpret them relative to the current directory on that
-- drive. UNC paths (\\server\share\...) are supported only when the server
-- and share already exist.
-- Path components are not sanitized; . and .. segments produce undefined behavior.
---@param path string
---@return boolean success
function utils.ensure_folder_exists(path)
	if utils.is_windows then
		path = path:gsub("/", "\\")
		local drive = path:match("^(%a:)[^\\]")
		if drive then
			path = drive .. "\\" .. path:sub(3)
		end
	end
	path = path:gsub("[/\\]+$", "")
	if path == "" then
		return true
	end
	if dir_is_accessible(path) then
		return true
	end
	-- Logged because this is the call that can flash a console window on
	-- Windows/WSL; if a future report says it fires every launch instead of
	-- once, this line (grep the wezterm log for "resurrect.utils") is the
	-- fastest way to confirm it and see which path is involved.
	local created = shell_mkdir(path)
	wezterm.log_info(
		("resurrect.utils: ensure_folder_exists creating %s (platform=%s) -> %s"):format(
			path,
			utils.is_windows and "windows" or "unix",
			created and "ok" or "failed"
		)
	)
	if created then
		-- Post-verify: confirm the directory is actually usable after creation.
		return dir_is_accessible(path)
	end
	return false
end

-- deep copy
---@param original table
---@return any copy
function utils.deepcopy(original)
	local copy
	if type(original) == "table" then
		copy = {}
		for k, v in pairs(original) do
			copy[k] = utils.deepcopy(v)
		end
	else
		copy = original
	end
	return copy
end

-- extend table
---@alias behavior
---| 'error' # Raises an error if a kye exists in multiple tables
---| 'keep'  # Uses the value from the leftmost table (first occurrence)
---| 'force' # Uses the value from the rightmost table (last occurrence)
---
---@param behavior behavior
---@param ... table
---@return table|nil
function utils.tbl_deep_extend(behavior, ...)
	local tables = { ... }
	if #tables == 0 then
		return {}
	end

	local result = {}
	for k, v in pairs(tables[1]) do
		if type(v) == "table" then
			result[k] = utils.deepcopy(v)
		else
			result[k] = v
		end
	end

	for i = 2, #tables do
		for k, v in pairs(tables[i]) do
			if type(result[k]) == "table" and type(v) == "table" then
				-- For nested tables, we recurse with the same behavior
				result[k] = utils.tbl_deep_extend(behavior, result[k], v)
			elseif result[k] ~= nil then
				-- Key exists in the result already
				if behavior == "error" then
					error("Key '" .. tostring(k) .. "' exists in multiple tables")
				elseif behavior == "force" then
					-- "force" uses value from rightmost table
					if type(v) == "table" then
						result[k] = utils.deepcopy(v)
					else
						result[k] = v
					end
				end
			-- "keep" keeps the leftmost value, which is already in result
			else
				-- Key doesn't exist in result yet, add it
				if type(v) == "table" then
					result[k] = utils.deepcopy(v)
				else
					result[k] = v
				end
			end
		end
	end

	return result
end

return utils
