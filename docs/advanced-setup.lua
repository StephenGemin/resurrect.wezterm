-- =============================================================================
-- resurrect.wezterm -- complete advanced configuration example.
--
-- Wires up every component individually via the underlying functions instead
-- of resurrect.setup(), which exists only for the common case. Use this file
-- as a menu: keep what you want, delete the rest.
--
-- Sections marked "pick ONE" are mutually exclusive alternatives for the same
-- keybinding -- never wire up more than one of them at once.
--
-- Drop this in as its own module (e.g. resurrect_plugin.lua) and from your
-- wezterm.lua: local resurrect_plugin = require('resurrect_plugin')
--              resurrect_plugin.setup(config)
--              -- merge resurrect_plugin.keys into config.keys
-- =============================================================================

local wezterm = require('wezterm')

local PLUGIN_URL = 'https://github.com/StephenGemin/resurrect.wezterm'

-- setup is a no-op default so callers can always invoke M.setup(config) safely
-- even if the plugin fails to load (pcall below returns early in that case).
local M = { keys = {}, setup = function() end }

local ok, resurrect = pcall(wezterm.plugin.require, PLUGIN_URL)
if not ok then
	wezterm.log_warn('resurrect.wezterm failed to load: ' .. tostring(resurrect))
	return M
end

function M.setup(config)
	-- --- Saving --------------------------------------------------------

	-- Event-driven save: fires on pane/tab structure changes and on window
	-- focus loss (e.g. alt-tab away). More responsive than periodic_save.
	resurrect.state_manager.event_driven_save({
		save_workspaces = true,
		save_windows = true,
		save_tabs = true,
		save_on_focus_loss = true,
	})

	-- Periodic save as a safety net.
	resurrect.state_manager.periodic_save({
		interval_seconds = 300,
		save_workspaces = true,
		save_windows = true,
		save_tabs = true,
	})

	-- --- Startup restore -------------------------------------------------

	-- Only has something to restore if save_workspaces = true above wrote a state file
	-- for the workspace to read back.
	wezterm.on('gui-startup', resurrect.state_manager.resurrect_on_gui_startup)

	-- --- Safe-restore process allowlist ----------------------------------

	-- Extend the built-in allowlist (vi, vim, nvim, emacs, man, less, more,
	-- top, htop, irssi, weechat, mutt):
	resurrect.pane_tree.add_safe_restore_processes({ 'lazygit', 'k9s' })
	-- ...or fully replace it (pass {} to disable process relaunch entirely):
	-- resurrect.pane_tree.set_safe_restore_processes({ 'vim', 'nvim' })
end

-- --- Keybindings -------------------------------------------------------------

M.keys = {
	-- Alt+Shift+N: create workspace (prompts for a name, doesn't save anything)
	{
		key = 'N',
		mods = 'ALT|SHIFT',
		action = resurrect.workspace_state.create_workspace_action(),
	},

	-- Alt+W: save workspace
	{
		key = 'w',
		mods = 'ALT',
		action = resurrect.workspace_state.save_workspace_action(),
	},

	-- Alt+Shift+W: save window (prompts for name on first use)
	{
		key = 'W',
		mods = 'ALT|SHIFT',
		action = resurrect.window_state.save_window_action(),
	},

	-- Alt+Shift+T: save tab (prompts for name on first use)
	{
		key = 'T',
		mods = 'ALT|SHIFT',
		action = resurrect.tab_state.save_tab_action(),
	},

	-- --- Restore: pick ONE of the following bindings for Alt+R -----------

	-- Option A: built-in fuzzy restore -- tag into and switch to the
	-- restored workspace (the fork's default behavior).
	{
		key = 'r',
		mods = 'ALT',
		action = resurrect.fuzzy_loader.restore_action({
			relative = true,
			restore_text = true,
			on_pane_restore = resurrect.pane_tree.default_on_pane_restore,
		}),
	},

	-- Option B: restore into the current workspace without switching
	-- (MLFlexer-equivalent behavior). See docs/migrating_from_mlflexer.md.
	-- {
	--   key = 'r',
	--   mods = 'ALT',
	--   action = wezterm.action_callback(function(win, pane)
	--     resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id)
	--       local state_type = id:match('^([^/]+)') -- "workspace" | "window" | "tab"
	--       local name = id:match('([^/]+)$'):match('(.+)%..+$') -- strip dir + ".json"
	--       if state_type == 'workspace' then
	--         resurrect.workspace_state.restore_workspace(resurrect.state_manager.load_state(name, 'workspace'), {
	--           relative = true,
	--           restore_text = true,
	--           on_pane_restore = resurrect.tab_state.default_on_pane_restore,
	--           spawn_in_workspace = false,
	--           switch_workspace = false,
	--         })
	--       end
	--     end)
	--   end),
	-- },

	-- Option C: manual dispatch -- full control over how each state type
	-- (workspace/window/tab) is restored.
	-- {
	--   key = 'r',
	--   mods = 'ALT',
	--   action = wezterm.action_callback(function(win, pane)
	--     resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id)
	--       local state_type = id:match('^([^/]+)')
	--       local name = id:match('([^/]+)$'):match('(.+)%..+$')
	--       local opts = {
	--         relative = true,
	--         restore_text = true,
	--         on_pane_restore = resurrect.pane_tree.default_on_pane_restore,
	--       }
	--       if state_type == 'workspace' then
	--         resurrect.workspace_state.restore_workspace(resurrect.state_manager.load_state(name, 'workspace'), opts)
	--       elseif state_type == 'window' then
	--         resurrect.window_state.restore_window(pane:window(), resurrect.state_manager.load_state(name, 'window'), opts)
	--       elseif state_type == 'tab' then
	--         local state = resurrect.state_manager.load_state(name, 'tab')
	--         local new_tab, new_pane = pane:window():spawn_tab({
	--           cwd = state.pane_tree and state.pane_tree.cwd or nil,
	--         })
	--         opts.pane = new_pane
	--         resurrect.tab_state.restore_tab(new_tab, state, opts)
	--       end
	--     end)
	--   end),
	-- },

	-- Option D: restore a saved window state into the *current* window,
	-- closing its other tabs so only the restored ones remain.
	-- {
	--   key = 'r',
	--   mods = 'ALT',
	--   action = wezterm.action_callback(function(win, pane)
	--     resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id)
	--       local state_type = id:match('^([^/]+)')
	--       local name = id:match('([^/]+)$'):match('(.+)%..+$')
	--       if state_type ~= 'window' then
	--         return
	--       end
	--       resurrect.window_state.restore_window(pane:window(), resurrect.state_manager.load_state(name, 'window'), {
	--         close_open_tabs = true, -- close this window's other tabs; only the restored ones remain
	--         window = pane:window(),
	--         on_pane_restore = resurrect.pane_tree.default_on_pane_restore,
	--         relative = true,
	--         restore_text = true,
	--       })
	--     end, { ignore_workspaces = true, ignore_tabs = true }) -- only offer window states
	--   end),
	-- },

	-- --- Delete: pick ONE of the following bindings for Alt+D ------------

	-- Option A: built-in fuzzy delete.
	{
		key = 'd',
		mods = 'ALT',
		action = resurrect.fuzzy_loader.delete_action(),
	},

	-- Option B: manual dispatch with a custom picker title/description.
	-- {
	--   key = 'd',
	--   mods = 'ALT',
	--   action = wezterm.action_callback(function(win, pane)
	--     resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id)
	--       resurrect.state_manager.delete_state(id)
	--     end, {
	--       title = 'Delete State',
	--       description = 'Select State to Delete and press Enter = accept, Esc = cancel, / = filter',
	--       fuzzy_description = 'Search State to Delete: ',
	--       is_fuzzy = true,
	--     })
	--   end),
	-- },
}

-- =============================================================================
-- Cosmetic extras -- entirely optional; delete this whole block if you don't
-- want a status-bar save indicator or toast notifications on plugin events.
-- =============================================================================

local base_setup = M.setup

function M.setup(config)
	base_setup(config)

	-- --- Status bar: show last save time ---------------------------------

	local last_save_time = nil
	wezterm.on('resurrect.state_manager.event_driven_save.finished', function()
		last_save_time = os.date('%H:%M:%S')
	end)
	wezterm.on('resurrect.state_manager.periodic_save.finished', function()
		last_save_time = os.date('%H:%M:%S')
	end)
	wezterm.on('update-right-status', function(window, _pane)
		window:set_right_status(wezterm.format({
			{ Foreground = { AnsiColor = 'Green' } },
			{ Text = last_save_time and ('saved ' .. last_save_time) or '' },
		}))
	end)

	-- --- Toast notification on error / write events ----------------------
	-- Suppresses the noisy write-finished event fired by periodic_save().

	local resurrect_event_listeners = {
		'resurrect.error',
		'resurrect.file_io.write_state.finished',
	}
	local is_periodic_save = false
	wezterm.on('resurrect.state_manager.periodic_save.start', function()
		is_periodic_save = true
	end)
	for _, event in ipairs(resurrect_event_listeners) do
		wezterm.on(event, function(...)
			if event == 'resurrect.file_io.write_state.finished' and is_periodic_save then
				is_periodic_save = false
				return
			end
			local args = { ... }
			local msg = event
			for _, v in ipairs(args) do
				msg = msg .. ' ' .. tostring(v)
			end
			wezterm.gui.gui_windows()[1]:toast_notification('Wezterm - resurrect', msg, nil, 4000)
		end)
	end
end

return M
