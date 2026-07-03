-- A restored pane replays its saved scrollback and the restore's "\r\n" makes
-- the shell print a fresh prompt, so a naive re-capture persists
-- [replay + fresh prompt] -- one extra prompt block per save->restore cycle,
-- forever. restore_baseline uses OSC 133 semantic zones to break that loop.
-- These specs pin the capture-side contract, whose failure modes are all
-- quiet: idle restored panes persist the replayed text byte-identical
-- (compounding), real activity is always captured live (data loss if not),
-- and panes without OSC 133 marks always capture live (frozen saved state if
-- not).

local helper = require("spec_helper")

describe("restored-pane idle check (restore_baseline)", function()
	local tab_state, pane_tree

	before_each(function()
		local wz = helper.new_wezterm()
		tab_state = helper.load("resurrect.tab_state", wz)
		-- Plain require so pane_tree shares tab_state's restore_baseline
		-- instance; a second helper.load would reset package.loaded and give
		-- the two modules different registries.
		pane_tree = require("resurrect.pane_tree")
	end)

	local BASELINE = "old output\r\nprompt>"
	local LIVE_CAPTURE = "old output\r\nprompt>\r\nfresh prompt>"

	-- BASELINE has one newline and the cursor sits at row 1 after inject, so
	-- rows 0-1 are the replay; zones from row 2 down are post-restore.
	local function make_pane(zones)
		local pane = {}
		function pane.pane_id(_)
			return 7
		end
		function pane.get_cursor_position(_)
			return { x = 0, y = 1 }
		end
		function pane.inject_output(_, _) end
		function pane.send_text(_, _) end
		function pane.get_domain_name(_)
			return "local"
		end
		function pane.get_current_working_dir(_)
			return { file_path = "/tmp" }
		end
		function pane.is_alt_screen_active(_)
			return false
		end
		function pane.get_dimensions(_)
			return { scrollback_rows = 100 }
		end
		function pane.get_lines_as_escapes(_, _)
			return LIVE_CAPTURE
		end
		function pane.get_semantic_zones(_, zone_type)
			return zones[zone_type] or {}
		end
		return pane
	end

	local function capture(pane)
		local tree = pane_tree.create_pane_tree({
			{ pane = pane, left = 0, top = 0, width = 80, height = 24, is_active = true },
		})
		return tree.text
	end

	it("persists the replayed text unchanged for an idle pane with OSC 133 marks", function()
		local pane = make_pane({
			-- An Output zone inside the replayed rows (an old command) plus the
			-- live fresh prompt below; nothing has run since the restore.
			Output = { { start_y = 0 } },
			Prompt = { { start_y = 2 } },
		})
		tab_state.default_on_pane_restore({ pane = pane, text = BASELINE })
		assert.are.equal(BASELINE, capture(pane))
	end)

	it("keeps the idle verdict across repeated saves, not just the first", function()
		local pane = make_pane({ Prompt = { { start_y = 2 } } })
		tab_state.default_on_pane_restore({ pane = pane, text = BASELINE })
		assert.are.equal(BASELINE, capture(pane))
		assert.are.equal(BASELINE, capture(pane))
	end)

	it("captures live once a command has produced output below the replay", function()
		local pane = make_pane({
			Output = { { start_y = 2 } },
			Prompt = { { start_y = 3 } },
		})
		tab_state.default_on_pane_restore({ pane = pane, text = BASELINE })
		assert.are.equal(LIVE_CAPTURE, capture(pane))
	end)

	it("captures live when the pane has no OSC 133 zones at all", function()
		local pane = make_pane({})
		tab_state.default_on_pane_restore({ pane = pane, text = BASELINE })
		assert.are.equal(LIVE_CAPTURE, capture(pane))
	end)
end)
