-- Integration tests for the one-call setup() entry point.
--
-- These mirror the minimal user config documented in README:
--
--   local resurrect = wezterm.plugin.require("https://github.com/YedPool/resurrect.wezterm")
--   resurrect.setup(config)
--
-- Each test loads init.lua the same way WezTerm does and then calls setup().
-- Failures here mean a user's wezterm.lua would error on load.

local helper = require("spec_helper")

-- Loads init.lua with dev.wezterm stubbed out (avoids network / plugin cache).
local function make_resurrect()
	local wz, rec = helper.new_wezterm({
		plugin_require = function()
			return { setup = function() return "/tmp/resurrect_integration_test" end }
		end,
	})
	local resurrect = helper.load("init", wz)
	return resurrect, rec
end

describe("resurrect.setup(config) — minimal user config", function()
	-- -----------------------------------------------------------------------
	-- Guard: setup() must not error when claude_hooks is explicitly disabled.
	-- This is the baseline — if even this fails, something more fundamental
	-- is broken than the process_handlers issue.
	-- -----------------------------------------------------------------------
	it("completes without error when claude_hooks=false", function()
		local resurrect = make_resurrect()
		assert.has_no.errors(function()
			resurrect.setup({ keys = {} }, { claude_hooks = false })
		end)
	end)

	it("creates config.keys when the table is absent and keybindings=true (default)", function()
		local resurrect = make_resurrect()
		local config = {}
		resurrect.setup(config, { claude_hooks = false })
		assert.is_table(config.keys)
		assert.is_true(#config.keys >= 1)
	end)

	it("injects at least 4 keybindings (save-workspace, save-window, save-tab, fuzzy-load)", function()
		local resurrect = make_resurrect()
		local config = { keys = {} }
		resurrect.setup(config, { claude_hooks = false })
		assert.is_true(#config.keys >= 4, "expected at least 4 keybindings, got " .. #config.keys)
	end)

	it("does not add any keybindings when keybindings=false", function()
		local resurrect = make_resurrect()
		local config = { keys = {} }
		resurrect.setup(config, { keybindings = false, claude_hooks = false })
		assert.are.equal(0, #config.keys)
	end)

	it("registers the gui-startup event for session restore on launch", function()
		local resurrect, rec = make_resurrect()
		resurrect.setup({ keys = {} }, { claude_hooks = false })
		local found = false
		for _, call in ipairs(rec.calls) do
			if call.name == "on" and call.event == "gui-startup" then
				found = true
				break
			end
		end
		assert.is_true(found, "gui-startup event handler was not registered")
	end)

	it("schedules periodic_save via wezterm.time.call_after", function()
		local resurrect, rec = make_resurrect()
		resurrect.setup({ keys = {} }, { claude_hooks = false })
		assert.not_nil(helper.find_call(rec, "call_after"), "periodic_save was not scheduled")
	end)

	-- -----------------------------------------------------------------------
	-- BUG: pub.process_handlers is never assigned in init(), so calling
	-- setup() with the default claude_hooks=true panics:
	--   "attempt to index a nil value (field 'process_handlers')"
	--
	-- Fix: create plugin/resurrect/process_handlers.lua and require it in
	-- init(), assigning the result to pub.process_handlers.
	-- -----------------------------------------------------------------------
	it("completes without error for fully default options (claude_hooks=true)", function()
		local resurrect = make_resurrect()
		assert.has_no.errors(function()
			resurrect.setup({ keys = {} })
		end)
	end)
end)
