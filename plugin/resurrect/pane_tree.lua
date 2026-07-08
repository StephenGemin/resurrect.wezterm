local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local restore_baseline = require("resurrect.restore_baseline")
local utils = require("resurrect.utils")

---@class pane_tree_module
---@field max_nlines integer
---@field process_restore_delay_seconds integer
local pub = {}
pub.max_nlines = 3500

-- Seconds to wait before sending a process-restore command to a pane.
-- Shells need a moment to initialise before they can accept input.
-- Set via resurrect.setup(config, { restore_delay = N }) or resurrect.pane_tree.process_restore_delay_seconds directly.
pub.process_restore_delay_seconds = 0

---@alias Pane any
---@alias PaneInformation {left: integer, top: integer, height: integer, width: integer}
---@alias pane_tree {left: integer, top: integer, height: integer, width: integer, bottom: pane_tree?, right: pane_tree?, text: string, cwd: string, domain?: string, process?: local_process_info?, pane: Pane?, is_active: boolean, is_zoomed: boolean, alt_screen_active: boolean}
---@alias local_process_info {name: string, argv: string[], cwd: string, executable: string}

---compare function returns true if a is more left than b
---@param a PaneInformation
---@param b PaneInformation
---@return boolean
local function compare_pane_by_coord(a, b)
	if a.left == b.left then
		return a.top < b.top
	else
		return a.left < b.left
	end
end

---@param root PaneInformation
---@param pane PaneInformation
---@return boolean
local function is_right(root, pane)
	if root.left + root.width < pane.left then
		return true
	end
	return false
end

---@param root PaneInformation
---@param pane PaneInformation
---@return boolean
local function is_bottom(root, pane)
	if root.top + root.height < pane.top then
		return true
	end
	return false
end

---@param root pane_tree
---@param panes PaneInformation
---@return pane_tree | nil
local function pop_connected_bottom(root, panes)
	for i, pane in ipairs(panes) do
		if root.left == pane.left and root.top + root.height + 1 == pane.top then
			table.remove(panes, i)
			return pane
		end
	end
end

---@param root pane_tree
---@param panes PaneInformation
---@return pane_tree | nil
local function pop_connected_right(root, panes)
	for i, pane in ipairs(panes) do
		if root.top == pane.top and root.left + root.width + 1 == pane.left then
			table.remove(panes, i)
			return pane
		end
	end
end

local NIX_STORE_PREFIX = "/nix/store/"
local NIX_VIM_EXECUTABLES = { vim = true, nvim = true, gvim = true }

-- Nix/NixOS installs executables under immutable, hash-suffixed store paths
-- (e.g. /nix/store/<hash>-neovim-unwrapped-.../bin/nvim) that go stale across
-- Nix generations or a garbage collection, so replaying a saved argv verbatim
-- can fail to restore a vim/nvim/gvim pane. There's no OS-level flag for
-- "this is Nix" the way utils.is_windows exists for Windows -- the
-- NIX_STORE_PREFIX check below is the only signal, and it makes this a no-op
-- on every platform that isn't Nix. Collapse the executable to its bare
-- command name (resolved via PATH on restore instead) and drop any --cmd/-c
-- flag whose value is itself a /nix/store path (Neovim bakes these in for
-- e.g. python3_host_prog).
---@param process_info local_process_info
local function sanitize_immutable_store_paths(process_info)
	if not process_info.executable or not process_info.executable:find(NIX_STORE_PREFIX, 1, true) then
		return
	end
	process_info.executable = process_info.name or process_info.executable

	if not process_info.argv then
		return
	end

	local is_vim = NIX_VIM_EXECUTABLES[process_info.executable]
	local argv = { process_info.executable }
	local pending_flag = nil
	for i, arg in ipairs(process_info.argv) do
		if i > 1 then
			if not is_vim then
				table.insert(argv, arg)
			elseif pending_flag then
				if not arg:find(NIX_STORE_PREFIX, 1, true) then
					table.insert(argv, pending_flag)
					table.insert(argv, arg)
				end
				pending_flag = nil
			elseif arg == "--cmd" or arg == "-c" then
				pending_flag = arg
			else
				table.insert(argv, arg)
			end
		end
	end
	process_info.argv = argv
end

---Extract the lowercased base command name from a process name/path,
---stripping any directory prefix and a Windows .exe suffix.
---@param proc_name string|nil
---@return string
local function base_name_of(proc_name)
	proc_name = proc_name or ""
	local base_name = proc_name:match("[/\\]?([^/\\]+)$") or proc_name
	return base_name:gsub("%.exe$", ""):lower()
end

-- Shells that can legitimately hold the foreground-process slot for an
-- instant after a short-lived alt-screen program (e.g. `man`'s pager) exits:
-- is_alt_screen_active() can still read true while get_foreground_process_info()
-- has already moved on to the shell that regained the pty. Falling through to
-- text capture instead of persisting "restore the shell" is always safe here.
local COMMON_SHELLS =
	{ bash = true, zsh = true, sh = true, dash = true, fish = true, ksh = true, tcsh = true, csh = true }

---@param root pane_tree | nil
---@param panes PaneInformation[]
---@return pane_tree | nil
local function insert_panes(root, panes)
	if root == nil then
		return nil
	end

	-- Guard against duplicate processing in symmetric layouts
	-- In a perfect cross layout, a pane can appear in both right and bottom branches
	-- If already processed by another branch, skip to avoid nil pane access
	if root.pane == nil then
		return root
	end

	local domain = root.pane:get_domain_name()
	if not wezterm.mux.get_domain(domain):is_spawnable() then
		wezterm.log_warn("Domain " .. domain .. " is not spawnable")
		wezterm.emit("resurrect.error", "Domain " .. domain .. " is not spawnable")
	else
		root.domain = domain

		if not root.pane:get_current_working_dir() then
			root.cwd = ""
		else
			root.cwd = root.pane:get_current_working_dir().file_path
			if utils.is_windows then
				-- WezTerm returns file_path as /C:/... on Windows; strip the leading slash.
				root.cwd = root.cwd:gsub("^/([a-zA-Z]):", "%1:")
				-- WSL mounts Windows drives at /mnt/c/...; convert to C:\... so that
				-- WezTerm's mux can validate the path in Windows context before spawning.
				root.cwd = root.cwd:gsub("^/mnt/([a-zA-Z])(.*)", function(drive, rest)
					return drive:upper() .. ":" .. rest:gsub("/", "\\")
				end)
			end
		end

		if domain == "local" then
			-- pane:inject_output() is unavailable for non-local domains,
			-- only saving local scrollback because it would slow down the process
			-- See: https://github.com/MLFlexer/resurrect.wezterm/issues/41
			root.alt_screen_active = root.pane:is_alt_screen_active()

			local process_info = nil
			if root.alt_screen_active then
				process_info = root.pane:get_foreground_process_info()
			end

			-- process_info can be nil even when alt_screen_active is true (observed
			-- with `top`), and it can be stale -- a shell that already regained the
			-- pty from a short-lived alt-screen program while is_alt_screen_active()
			-- still reads true from a moment earlier. Both fall through to text
			-- capture rather than persisting a bogus/missing process or crashing.
			if process_info and not COMMON_SHELLS[base_name_of(process_info.name or process_info.executable or "")] then
				process_info.children = nil
				process_info.pid = nil
				process_info.ppid = nil
				sanitize_immutable_store_paths(process_info)
				root.process = process_info
			else
				-- Preserve the invariant that alt_screen_active reflects which capture
				-- strategy was actually used (process vs. text), not a raw terminal-mode
				-- read -- both fallback cases above land here with a stale/missing
				-- process, so this is a no-op when alt-screen was never active and a
				-- correction when it was.
				root.alt_screen_active = false

				-- A restored pane that is untouched since restore keeps its
				-- replayed baseline byte-identical; persisting the capture
				-- would also pick up the fresh prompt the restore triggered
				-- and grow the saved state by one prompt block per
				-- save->restore cycle.
				local captured = utils.capture_pane_text(root.pane, pub.max_nlines)
				root.text = restore_baseline.text_to_persist(root.pane, captured)
			end
		end
	end

	root.pane = nil

	if #panes == 0 then
		return root
	end

	local right, bottom = {}, {}
	for _, pane in ipairs(panes) do
		if is_right(root, pane) then
			table.insert(right, pane)
		end
		if is_bottom(root, pane) then
			table.insert(bottom, pane)
		end
	end

	if #right > 0 then
		local right_child = pop_connected_right(root, right)
		root.right = insert_panes(right_child, right)
	end

	if #bottom > 0 then
		local bottom_child = pop_connected_bottom(root, bottom)
		root.bottom = insert_panes(bottom_child, bottom)
	end

	return root
end

---Create a pane tree from a list of PaneInformation
---@param panes PaneInformation
---@return pane_tree | nil
function pub.create_pane_tree(panes)
	table.sort(panes, compare_pane_by_coord)
	local root = table.remove(panes, 1)
	return insert_panes(root, panes)
end

---maps over the pane tree
---@param pane_tree pane_tree
---@param f fun(pane_tree: pane_tree): pane_tree
---@return nil
function pub.map(pane_tree, f)
	if pane_tree == nil then
		return nil
	end

	pane_tree = f(pane_tree)
	if pane_tree.right then
		pub.map(pane_tree.right, f)
	end
	if pane_tree.bottom then
		pub.map(pane_tree.bottom, f)
	end

	return pane_tree
end

function pub.fold(pane_tree, acc, f)
	if pane_tree == nil then
		return acc
	end

	acc = f(acc, pane_tree)
	if pane_tree.right then
		acc = pub.fold(pane_tree.right, acc, f)
	end
	if pane_tree.bottom then
		acc = pub.fold(pane_tree.bottom, acc, f)
	end

	return acc
end

-- Known safe executables that can be restored via send_text.
-- Process names not in this set will be logged but not auto-launched,
-- preventing arbitrary command execution from tampered state files.
-- Customize via pub.add_safe_restore_processes()/pub.set_safe_restore_processes()
-- or resurrect.setup(config, { safe_restore_processes = { add = {...} } }).
-- Mirrors tmux-resurrect's default @resurrect-processes list:
-- https://github.com/tmux-plugins/tmux-resurrect/blob/master/docs/restoring_programs.md
local SAFE_RESTORE_PROCESSES = {
	vi = true,
	vim = true,
	nvim = true,
	emacs = true,
	-- uncomment when fixed alt-screen/process-capture race producing bogus "unrecognized process" restores
	-- man = true,
	less = true,
	more = true,
	top = true,
	htop = true,
	irssi = true,
	weechat = true,
	mutt = true,
}

---Adds additional process names to the safe-restore allowlist, on top of the
---built-in defaults.
---@param names string[]
function pub.add_safe_restore_processes(names)
	for _, name in ipairs(names) do
		SAFE_RESTORE_PROCESSES[name:lower()] = true
	end
end

---Replaces the safe-restore allowlist entirely, discarding the built-in
---defaults. Pass an empty table to disable process relaunch on restore.
---@param names string[]
function pub.set_safe_restore_processes(names)
	SAFE_RESTORE_PROCESSES = {}
	pub.add_safe_restore_processes(names)
end

--- Function to restore text or processes when restoring panes
---@param pane_tree pane_tree
function pub.default_on_pane_restore(pane_tree)
	local pane = pane_tree.pane

	-- Spawn process if using alt screen, otherwise restore text
	if pane_tree.alt_screen_active and pane_tree.process and pane_tree.process.argv then
		local base_name = base_name_of(pane_tree.process.name)

		if SAFE_RESTORE_PROCESSES[base_name] then
			local cmd = wezterm.shell_join_args(pane_tree.process.argv) .. "\r\n"
			if pub.process_restore_delay_seconds > 0 then
				wezterm.time.call_after(pub.process_restore_delay_seconds, function()
					pane:send_text(cmd)
				end)
			else
				pane:send_text(cmd)
			end
		else
			-- base_name comes from process.name, which some programs set to something
			-- other than their executable (e.g. a version string) -- log the executable
			-- path too so the actual command is identifiable, not just that opaque name.
			-- argv is deliberately omitted: it can carry secrets (tokens, passwords) that
			-- shouldn't end up in the log.
			wezterm.log_warn(
				"resurrect: skipping restore of unrecognized process: "
					.. base_name
					.. " (executable: "
					.. (pane_tree.process.executable or "?")
					.. ") (add to SAFE_RESTORE_PROCESSES if intended)"
			)
		end
	elseif pane_tree.text then
		-- Kept as a defensive pass for state files saved before capture-time
		-- trimming existed; a no-op for freshly saved state.
		local text = utils.strip_trailing_blank_rows(pane_tree.text)
		-- Append the newline to the injected output instead of sending it to the
		-- shell. The shell already paints its own fresh prompt on startup; the
		-- newline is only needed to leave the cursor at column 0 so that prompt
		-- lands on a clean line below the replay. (Without it the shell prints a
		-- reverse-video partial-line "%" marker over the last replayed row.)
		-- Sending "\r\n" to the shell instead made it accept TWO empty lines -- CR
		-- and LF each fire accept-line -- drawing two spurious prompt blocks per
		-- restore on top of the startup one. register() gets the un-appended text
		-- so the persisted baseline stays exactly what was replayed.
		pane:inject_output(text .. "\r\n")
		restore_baseline.register(pane, text)
	end
end

return pub
