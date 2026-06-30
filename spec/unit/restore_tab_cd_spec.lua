-- restore_tab used to send a live `cd` to opts.pane whenever it was set, even for
-- panes spawned fresh with the correct cwd already passed at spawn time. That redundant
-- `cd` ends up baked into the pane's real scrollback, gets captured by autosave, and
-- compounds across restarts. pane_needs_cd is the signal that distinguishes "genuinely
-- reused pane, needs a cd" from "freshly spawned, already in the right place".

local helper = require("spec_helper")

describe("tab_state.restore_tab cd handling", function()
	local tab_state, rec

	local function sample_tab_state()
		return {
			pane_tree = { cwd = "/home/testuser/project", is_active = true },
		}
	end

	local function make_pane()
		local sent = {}
		local pane = {
			activate = function() end,
		}
		function pane.send_text(_, text)
			table.insert(sent, text)
		end
		return pane, sent
	end

	before_each(function()
		local wz
		wz, rec = helper.new_wezterm()
		tab_state = helper.load("resurrect.tab_state", wz)
	end)

	it("does not send a cd to a freshly spawned pane (pane_needs_cd unset)", function()
		local pane, sent = make_pane()
		tab_state.restore_tab({}, sample_tab_state(), { pane = pane })
		assert.are.equal(0, #sent)
	end)

	it("sends a cd when reusing an already-running pane (pane_needs_cd set)", function()
		local pane, sent = make_pane()
		tab_state.restore_tab({}, sample_tab_state(), { pane = pane, pane_needs_cd = true })
		assert.are.equal(1, #sent)
		assert.are.equal("cd /home/testuser/project\r\n", sent[1])
	end)

	it("clears pane_needs_cd after use so it can't leak into the next tab", function()
		local pane = make_pane()
		local opts = { pane = pane, pane_needs_cd = true }
		tab_state.restore_tab({}, sample_tab_state(), opts)
		assert.is_nil(opts.pane_needs_cd)
	end)
end)
