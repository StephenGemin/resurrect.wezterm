local wezterm = require("wezterm") --[[@as Wezterm]]
local file_io = require("resurrect.file_io")

local pub = {}

-- Processes that should be saved as a command (not scrollback) even when they
-- are not running in alt-screen mode. Claude Code is the primary example: it
-- keeps the terminal in normal-screen mode but should be relaunched on restore.
local HANDLED_PROCESSES = {
	claude = true,
}

--- Returns true if the process has a registered handler, nil otherwise.
---@param process_info local_process_info?
---@return boolean|nil
function pub.find_handler(process_info)
	if not process_info then
		return nil
	end
	local name = process_info.name or ""
	local base = name:match("[/\\]?([^/\\]+)$") or name
	base = base:gsub("%.exe$", ""):lower()
	return HANDLED_PROCESSES[base] or nil
end

--- Reads the pane-session file written by setup_claude_session_hooks.
--- Returns the parsed session table, or nil if no session is recorded for this pane.
---@param pane_id integer
---@return table|nil
function pub.read_pane_session(pane_id)
	local sm = require("resurrect.state_manager")
	local utils = require("resurrect.utils")
	local path = sm.save_state_dir .. "pane_sessions" .. utils.separator .. tostring(pane_id) .. ".json"
	return file_io.load_json(path)
end

--- Registers a WezTerm user-var-changed hook that tracks Claude Code sessions.
--- Claude Code must send the CLAUDE_SESSION_ID user variable on start (via a
--- SessionStart hook in .claude/settings.json). This function writes a pane-
--- session file so read_pane_session() can identify Claude Code panes even
--- when a child process (bash, node, etc.) is the foreground process.
function pub.setup_claude_session_hooks()
	wezterm.on("user-var-changed", function(_window, pane, name, value)
		if name ~= "CLAUDE_SESSION_ID" then
			return
		end
		local sm = require("resurrect.state_manager")
		local utils = require("resurrect.utils")
		local dir = sm.save_state_dir .. "pane_sessions"
		utils.ensure_folder_exists(dir)
		local path = dir .. utils.separator .. tostring(pane:pane_id()) .. ".json"
		local ok, err = file_io.write_file(path, wezterm.json_encode({ session_id = value }))
		if not ok then
			wezterm.log_error("resurrect: failed to write pane session: " .. tostring(err))
			wezterm.emit("resurrect.error", "Failed to write pane session: " .. tostring(err))
		end
	end)
end

return pub
