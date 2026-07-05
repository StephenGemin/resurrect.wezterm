-- A restored pane replays its saved scrollback and the fresh shell then
-- paints its own first prompt, so a naive re-capture persists
-- [replay + fresh prompt] -- one extra prompt block per save->restore cycle,
-- forever. restore_baseline polls until the fresh prompt has painted and the
-- pane is quiescent, then persists the replay byte-identically for as long
-- as captures still equal that snapshot. These specs pin the capture-side contract, whose
-- failure modes are all quiet: idle restored panes persist the replayed text
-- byte-identical (compounding returns if not), any content change is captured
-- live (data loss if not), and activity during the settle window must not be
-- frozen into the snapshot (data loss if it is).

local helper = require("spec_helper")

describe("restored-pane idle check (restore_baseline)", function()
	local wz, tab_state, pane_tree

	before_each(function()
		wz = helper.new_wezterm()
		tab_state = helper.load("resurrect.tab_state", wz)
		-- Plain require so pane_tree shares tab_state's restore_baseline
		-- instance; a second helper.load would reset package.loaded and give
		-- the two modules different registries.
		pane_tree = require("resurrect.pane_tree")
	end)

	local BASELINE = "old output\r\nprompt>"
	local SETTLED = BASELINE .. "\r\n\r\nfresh prompt>"

	local function make_pane()
		local pane = { content = BASELINE }
		function pane.pane_id(_)
			return 7
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
			return pane.content
		end
		function pane.get_foreground_process_info(_)
			return { name = "zsh", executable = "/bin/zsh" }
		end
		return pane
	end

	-- Drain the settle poll chain scheduled by register(): the harness records
	-- call_after callbacks instead of executing them on a timer, and each poll
	-- schedules the next until the pane settles, so keep firing pending ones.
	local function settle()
		local fired = true
		while fired do
			fired = false
			for _, call in ipairs(wz._rec.calls) do
				if call.name == "call_after" and not call.done then
					call.done = true
					call.fn()
					fired = true
					break
				end
			end
		end
	end

	local function restore(pane)
		tab_state.default_on_pane_restore({ pane = pane, text = BASELINE })
	end

	local function capture(pane)
		local tree = pane_tree.create_pane_tree({
			{ pane = pane, left = 0, top = 0, width = 80, height = 24, is_active = true },
		})
		return tree.text
	end

	it("persists the replayed text unchanged for an idle pane", function()
		local pane = make_pane()
		restore(pane)
		pane.content = SETTLED
		settle()
		assert.are.equal(BASELINE, capture(pane))
	end)

	it("keeps the idle verdict across repeated saves, not just the first", function()
		local pane = make_pane()
		restore(pane)
		pane.content = SETTLED
		settle()
		assert.are.equal(BASELINE, capture(pane))
		assert.are.equal(BASELINE, capture(pane))
	end)

	it("captures live once the pane's content changes after settle", function()
		local pane = make_pane()
		restore(pane)
		pane.content = SETTLED
		settle()
		pane.content = SETTLED .. "\r\nhello"
		assert.are.equal(SETTLED .. "\r\nhello", capture(pane))
	end)

	it("captures live when saving before the settle snapshot exists", function()
		local pane = make_pane()
		restore(pane)
		pane.content = SETTLED
		assert.are.equal(SETTLED, capture(pane))
	end)

	it("does not freeze activity that happened during the settle window", function()
		local pane = make_pane()
		restore(pane)
		local burst = BASELINE .. string.rep("\r\nout", 12)
		pane.content = burst
		settle()
		assert.are.equal(burst, capture(pane))
	end)
end)
