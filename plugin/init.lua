local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm

-- Restore package.path so sub-modules under plugin/resurrect/ can be required.
-- wezterm.plugin.require() does not add the plugin dir to package.path automatically.
local sep = package.config:sub(1, 1)
for _, plugin in ipairs(wezterm.plugin.list()) do
	if plugin.url:find("resurrect", 1, true) then
		package.path = plugin.plugin_dir .. sep .. "plugin" .. sep .. "?.lua;" .. package.path
		break
	end
end

local pub = {}

local function init()
	pub.workspace_state = require("resurrect.workspace_state")
	pub.window_state = require("resurrect.window_state")
	pub.tab_state = require("resurrect.tab_state")
	pub.pane_tree = require("resurrect.pane_tree")
	pub.fuzzy_loader = require("resurrect.fuzzy_loader")
	pub.state_manager = require("resurrect.state_manager")
end

init()

--- One-call setup that configures everything for session persistence.
--- Users call this from their wezterm.lua:
---
---   local resurrect = wezterm.plugin.require("https://github.com/StephenGemin/resurrect.wezterm")
---   resurrect.setup(config)  -- or resurrect.setup(config, opts)
---
--- Options (all optional):
---   periodic_interval  = 300    -- seconds between periodic saves
---   restore_delay      = 3      -- seconds to wait before sending restore commands
---   save_workspaces    = true
---   save_windows       = true
---   save_tabs          = true
---   save_on_focus_loss = true   -- also save immediately when a window loses OS focus (e.g. alt-tab away)
---   switch_workspace   = nil    -- default for restore's switch_workspace opt; nil follows spawn_in_workspace
---   keybindings        = true   -- add Alt+W/R/Shift+W/Shift+T bindings
---   status_bar         = true   -- show save time + tab titles in right status
---   safe_restore_processes = { add = {...} } or { replace = {...} } -- extend/replace
---                                the allowlist of processes relaunched on restore
---
---@alias setup_opts {periodic_interval: integer?, restore_delay: integer?, save_workspaces: boolean?, save_windows: boolean?, save_tabs: boolean?, save_on_focus_loss: boolean?, switch_workspace: boolean?, keybindings: boolean?, status_bar: boolean?, safe_restore_processes: {add: string[]?, replace: string[]?}?}

---@param config table wezterm config_builder object
---@param opts? setup_opts optional overrides
function pub.setup(config, opts)
	opts = opts or {}
	local save_workspaces = opts.save_workspaces ~= false
	local save_windows = opts.save_windows ~= false
	local save_tabs = opts.save_tabs ~= false
	local save_on_focus_loss = opts.save_on_focus_loss ~= false

	-- Event-driven save: fires on pane/tab structure changes and window focus loss
	pub.state_manager.event_driven_save({
		save_workspaces = save_workspaces,
		save_windows = save_windows,
		save_tabs = save_tabs,
		save_on_focus_loss = save_on_focus_loss,
	})

	-- Periodic save as a safety net
	pub.state_manager.periodic_save({
		interval_seconds = opts.periodic_interval or 300,
		save_workspaces = save_workspaces,
		save_windows = save_windows,
		save_tabs = save_tabs,
	})

	-- Restore delay for process commands (shells need time to init)
	if opts.restore_delay then
		pub.pane_tree.process_restore_delay_seconds = opts.restore_delay
	end

	-- Default for restore_workspace's switch_workspace opt (per-call opt still wins).
	-- Startup restore always switches regardless; this governs mid-session restores.
	if opts.switch_workspace ~= nil then
		pub.workspace_state.switch_workspace_default = opts.switch_workspace
	end

	-- Safe-restore process allowlist: extend or replace the defaults
	if opts.safe_restore_processes then
		if opts.safe_restore_processes.replace then
			pub.pane_tree.set_safe_restore_processes(opts.safe_restore_processes.replace)
		elseif opts.safe_restore_processes.add then
			pub.pane_tree.add_safe_restore_processes(opts.safe_restore_processes.add)
		end
	end

	-- Restore workspace on startup
	wezterm.on("gui-startup", pub.state_manager.resurrect_on_gui_startup)

	-- Status bar: show save time + tab titles
	if opts.status_bar ~= false then
		local last_save_time = nil

		wezterm.on("resurrect.state_manager.event_driven_save.finished", function()
			last_save_time = os.date("%H:%M:%S")
		end)

		wezterm.on("resurrect.state_manager.periodic_save.finished", function()
			last_save_time = os.date("%H:%M:%S")
		end)

		wezterm.on("update-right-status", function(window, _pane)
			local titles = {}
			local mux_win = window:mux_window()
			for _, tab in ipairs(mux_win:tabs()) do
				local title = tab:get_title() or ""
				if title ~= "" then
					titles[title] = (titles[title] or 0) + 1
				end
			end

			local parts = {}
			for title, count in pairs(titles) do
				if count > 1 then
					table.insert(parts, title .. " x" .. count)
				else
					table.insert(parts, title)
				end
			end
			table.sort(parts)
			local title_str = table.concat(parts, ", ")

			local status = ""
			if last_save_time then
				status = "saved " .. last_save_time .. " | " .. title_str
			elseif title_str ~= "" then
				status = title_str
			end

			window:set_right_status(wezterm.format({
				{ Foreground = { AnsiColor = "Green" } },
				{ Text = status },
			}))
		end)
	end

	-- Default keybindings for create/save/restore/delete
	if opts.keybindings ~= false then
		config.keys = config.keys or {}

		-- Alt+Shift+N: create workspace
		table.insert(config.keys, {
			key = "N",
			mods = "ALT|SHIFT",
			action = pub.workspace_state.create_workspace_action(),
		})

		-- Alt+W: save workspace
		table.insert(config.keys, {
			key = "w",
			mods = "ALT",
			action = pub.workspace_state.save_workspace_action(),
		})

		-- Alt+S: save workspace + current window
		table.insert(config.keys, {
			key = "s",
			mods = "ALT",
			action = wezterm.action_callback(function(win, _pane)
				local state_manager = require("resurrect.state_manager")
				state_manager.save_state(pub.workspace_state.get_workspace_state())
				state_manager.save_state(pub.window_state.get_window_state(win:mux_window()))
			end),
		})

		-- Alt+Shift+W: save window
		table.insert(config.keys, {
			key = "W",
			mods = "ALT|SHIFT",
			action = pub.window_state.save_window_action(),
		})

		-- Alt+Shift+T: save tab
		table.insert(config.keys, {
			key = "T",
			mods = "ALT|SHIFT",
			action = pub.tab_state.save_tab_action(),
		})

		-- Alt+R: fuzzy restore saved state
		table.insert(config.keys, {
			key = "r",
			mods = "ALT",
			action = pub.fuzzy_loader.restore_action(),
		})

		-- Alt+D: fuzzy delete saved state
		table.insert(config.keys, {
			key = "d",
			mods = "ALT",
			action = pub.fuzzy_loader.delete_action(),
		})
	end
end

return pub
